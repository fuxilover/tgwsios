// tgwsproxyd.m
//
// Local SOCKS5 -> WebSocket(TLS) bridge for Telegram, inspired by
// Flowseal/tg-ws-proxy (MIT). This is an independent, clean-room
// reimplementation for iOS (rootless/rootful jailbreak), using the same
// public idea the official Android port uses: run a local SOCKS5 proxy,
// point Telegram's own "SOCKS5 proxy" setting at it, and transparently
// tunnel the MTProto TCP stream to Telegram's datacenters over wss://
// so it isn't recognizable as plain MTProto traffic to a censor.
//
// NOTE: this does NOT intercept system-wide traffic. Only apps that are
// explicitly configured to use this SOCKS5 proxy (i.e. Telegram, via its
// Settings -> Data and Storage -> Proxy) will be routed through it.
//
// Build with Theos (see Makefile). Runs as a launchd daemon.

#import <Foundation/Foundation.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <fcntl.h>
#import <errno.h>

// ---------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------

static NSString *FirstExistingPath(NSArray<NSString *> *candidates) {
    for (NSString *p in candidates) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:p]) return p;
    }
    return candidates.lastObject;
}

@interface TGWSConfig : NSObject
@property (nonatomic) uint16_t port;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *ipToDc;   // "149.154.167.220" -> @2
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSString *> *dcToHost; // @2 -> "venus.web.telegram.org"
@property (nonatomic, strong) NSString *logPath;
+ (instancetype)load;
@end

@implementation TGWSConfig

+ (instancetype)load {
    TGWSConfig *c = [TGWSConfig new];
    c.port = 1080;
    c.ipToDc = [NSMutableDictionary new];
    c.dcToHost = [NSMutableDictionary new];

    // Sensible defaults matching upstream tg-ws-proxy docs: only DC2/DC4
    // are reliably accelerated; everything else falls back to direct TCP.
    c.dcToHost[@1] = @"pluto.web.telegram.org";
    c.dcToHost[@2] = @"venus.web.telegram.org";
    c.dcToHost[@3] = @"aurora.web.telegram.org";
    c.dcToHost[@4] = @"vesta.web.telegram.org";
    c.dcToHost[@5] = @"flora.web.telegram.org";

    c.ipToDc[@"149.154.175.50"]  = @1;
    c.ipToDc[@"149.154.167.51"]  = @2;
    c.ipToDc[@"149.154.167.220"] = @2; // common alt/media IP for DC2
    c.ipToDc[@"149.154.175.100"] = @3;
    c.ipToDc[@"149.154.167.91"]  = @4;
    c.ipToDc[@"91.108.56.130"]   = @5;

    NSString *confPath = FirstExistingPath(@[
        @"/var/jb/etc/tgwsproxy.conf", // rootless (roothide/Dopamine)
        @"/etc/tgwsproxy.conf",        // rootful
    ]);
    c.logPath = [[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb"] ?
        @"/var/jb/var/log/tgwsproxy.log" : @"/var/log/tgwsproxy.log";

    NSError *err = nil;
    NSString *contents = [NSString stringWithContentsOfFile:confPath encoding:NSUTF8StringEncoding error:&err];
    if (contents) {
        for (NSString *rawLine in [contents componentsSeparatedByString:@"\n"]) {
            NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (line.length == 0 || [line hasPrefix:@"#"]) continue;
            NSRange eq = [line rangeOfString:@"="];
            if (eq.location == NSNotFound) continue;
            NSString *key = [[line substringToIndex:eq.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            NSString *val = [[line substringFromIndex:eq.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if ([key isEqualToString:@"PORT"]) {
                c.port = (uint16_t)[val integerValue];
            } else if ([key hasPrefix:@"DC_HOST_"]) {
                NSNumber *dc = @([[key substringFromIndex:8] integerValue]);
                c.dcToHost[dc] = val;
            } else if ([key hasPrefix:@"DC_IP_"]) {
                NSNumber *dc = @([[key substringFromIndex:6] integerValue]);
                for (NSString *ip in [val componentsSeparatedByString:@","]) {
                    NSString *trimmed = [ip stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    if (trimmed.length) c.ipToDc[trimmed] = dc;
                }
            }
        }
    }
    return c;
}

@end

static TGWSConfig *gConfig;

static void TGWLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], msg];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:gConfig.logPath];
    if (!fh) {
        [[NSFileManager defaultManager] createFileAtPath:gConfig.logPath contents:nil attributes:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:gConfig.logPath];
    }
    [fh seekToEndOfFile];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
    fprintf(stderr, "%s", line.UTF8String);
}

// ---------------------------------------------------------------------
// Low level helpers
// ---------------------------------------------------------------------

static void SetNonBlocking(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

// Best-effort blocking write of a small buffer to a raw fd (SOCKS
// handshake replies are tiny, so looping here is fine).
static void WriteAll(int fd, const void *buf, size_t len) {
    const uint8_t *p = buf;
    size_t left = len;
    while (left > 0) {
        ssize_t n = write(fd, p, left);
        if (n > 0) { p += n; left -= n; continue; }
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) {
            usleep(1000);
            continue;
        }
        break;
    }
}

// ---------------------------------------------------------------------
// SocksSession: one client connection, either bridged to a WebSocket
// (Telegram DC) or passed through directly over raw TCP (fallback).
// ---------------------------------------------------------------------

typedef NS_ENUM(NSInteger, TGWState) {
    TGWStateGreeting,
    TGWStateRequest,
    TGWStateRelayWS,
    TGWStateRelayTCP,
    TGWStateClosed,
};

@interface SocksSession : NSObject <NSURLSessionWebSocketDelegate>
@property (nonatomic) int clientFD;
@property (nonatomic) int remoteFD; // used only for direct-TCP fallback
@property (nonatomic) TGWState state;
@property (nonatomic, strong) NSMutableData *inbuf;
@property (nonatomic, strong) dispatch_source_t clientReadSrc;
@property (nonatomic, strong) dispatch_source_t remoteReadSrc;
@property (nonatomic, strong) NSURLSession *urlSession;
@property (nonatomic, strong) NSURLSessionWebSocketTask *wsTask;
@property (nonatomic, copy) NSString *destHost;
@property (nonatomic) uint16_t destPort;
@property (nonatomic, copy) void (^onClose)(SocksSession *);
- (instancetype)initWithFD:(int)fd;
- (void)start;
@end

@implementation SocksSession

- (instancetype)initWithFD:(int)fd {
    if ((self = [super init])) {
        _clientFD = fd;
        _remoteFD = -1;
        _state = TGWStateGreeting;
        _inbuf = [NSMutableData new];
        SetNonBlocking(fd);
    }
    return self;
}

- (void)start {
    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    self.clientReadSrc = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, self.clientFD, 0, q);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.clientReadSrc, ^{ [weakSelf clientReadable]; });
    dispatch_source_set_cancel_handler(self.clientReadSrc, ^{ /* fd closed elsewhere */ });
    dispatch_resume(self.clientReadSrc);
}

- (void)closeAll {
    if (self.state == TGWStateClosed) return;
    self.state = TGWStateClosed;
    if (self.clientReadSrc) dispatch_source_cancel(self.clientReadSrc);
    if (self.remoteReadSrc) dispatch_source_cancel(self.remoteReadSrc);
    if (self.clientFD >= 0) { close(self.clientFD); self.clientFD = -1; }
    if (self.remoteFD >= 0) { close(self.remoteFD); self.remoteFD = -1; }
    [self.wsTask cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
    [self.urlSession invalidateAndCancel];
    if (self.onClose) self.onClose(self);
}

// -------------------- reading from the SOCKS client --------------------

- (void)clientReadable {
    uint8_t buf[8192];
    ssize_t n = read(self.clientFD, buf, sizeof(buf));
    if (n <= 0) {
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return;
        [self closeAll];
        return;
    }
    if (self.state == TGWStateRelayWS) {
        NSData *chunk = [NSData dataWithBytes:buf length:n];
        [self.wsTask sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithData:chunk]
                completionHandler:^(NSError * _Nullable error) {
            if (error) { TGWLog(@"ws send error: %@", error); [self closeAll]; }
        }];
        return;
    }
    if (self.state == TGWStateRelayTCP) {
        WriteAll(self.remoteFD, buf, (size_t)n);
        return;
    }
    [self.inbuf appendBytes:buf length:n];
    [self pumpParser];
}

- (void)pumpParser {
    if (self.state == TGWStateGreeting) {
        const uint8_t *b = self.inbuf.bytes;
        if (self.inbuf.length < 2) return;
        uint8_t nmethods = b[1];
        if (self.inbuf.length < (NSUInteger)(2 + nmethods)) return;
        // Reply: version 5, method 0 (no auth).
        uint8_t reply[2] = {0x05, 0x00};
        WriteAll(self.clientFD, reply, sizeof(reply));
        [self.inbuf replaceBytesInRange:NSMakeRange(0, 2 + nmethods) withBytes:NULL length:0];
        self.state = TGWStateRequest;
        if (self.inbuf.length) [self pumpParser];
        return;
    }
    if (self.state == TGWStateRequest) {
        const uint8_t *b = self.inbuf.bytes;
        if (self.inbuf.length < 4) return;
        uint8_t cmd = b[1];
        uint8_t atyp = b[3];
        NSUInteger need = 4;
        NSString *host = nil;
        if (atyp == 0x01) { // IPv4
            need += 4 + 2;
            if (self.inbuf.length < need) return;
            char ipstr[INET_ADDRSTRLEN];
            inet_ntop(AF_INET, b + 4, ipstr, sizeof(ipstr));
            host = @(ipstr);
        } else if (atyp == 0x03) { // domain name
            uint8_t len = b[4];
            need += 1 + len + 2;
            if (self.inbuf.length < need) return;
            host = [[NSString alloc] initWithBytes:b + 5 length:len encoding:NSUTF8StringEncoding];
        } else if (atyp == 0x04) { // IPv6 - parsed but we only really support v4 DC IPs
            need += 16 + 2;
            if (self.inbuf.length < need) return;
            char ipstr[INET6_ADDRSTRLEN];
            inet_ntop(AF_INET6, b + 4, ipstr, sizeof(ipstr));
            host = @(ipstr);
        } else {
            TGWLog(@"unsupported ATYP %d", atyp);
            [self closeAll];
            return;
        }
        uint16_t port = (uint16_t)((b[need - 2] << 8) | b[need - 1]);
        [self.inbuf replaceBytesInRange:NSMakeRange(0, need) withBytes:NULL length:0];

        if (cmd != 0x01) { // only CONNECT is supported
            uint8_t fail[10] = {0x05, 0x07, 0x00, 0x01, 0,0,0,0, 0,0};
            WriteAll(self.clientFD, fail, sizeof(fail));
            [self closeAll];
            return;
        }
        self.destHost = host;
        self.destPort = port;
        [self beginConnect];
        return;
    }
}

// -------------------- deciding WS bridge vs direct TCP --------------------

- (void)beginConnect {
    NSNumber *dc = gConfig.ipToDc[self.destHost];
    NSString *wsHost = dc ? gConfig.dcToHost[dc] : nil;
    if (wsHost) {
        TGWLog(@"CONNECT %@:%d -> DC%@ via wss://%@/apiws", self.destHost, self.destPort, dc, wsHost);
        [self connectWebSocket:wsHost];
    } else {
        TGWLog(@"CONNECT %@:%d -> direct TCP (no DC mapping)", self.destHost, self.destPort);
        [self connectDirectTCP];
    }
}

- (void)connectWebSocket:(NSString *)host {
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"wss://%@/apiws", host]];
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    self.urlSession = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];
    self.wsTask = [self.urlSession webSocketTaskWithURL:url];
    [self.wsTask resume];
    // Fallback to direct TCP if the WS handshake doesn't complete quickly.
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (strongSelf && strongSelf.state == TGWStateGreeting /*unused sentinel*/) return;
        if (strongSelf && strongSelf.wsTask.state != NSURLSessionTaskStateRunning) return;
        if (strongSelf && strongSelf.state != TGWStateRelayWS && strongSelf.state != TGWStateClosed) {
            TGWLog(@"WS handshake timeout for %@, falling back to direct TCP", host);
            [strongSelf.wsTask cancel];
            [strongSelf connectDirectTCP];
        }
    });
}

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)task
didOpenWithProtocol:(NSString *)protocol {
    if (self.state == TGWStateClosed) return;
    self.state = TGWStateRelayWS;
    uint8_t ok[10] = {0x05, 0x00, 0x00, 0x01, 0,0,0,0, 0,0};
    WriteAll(self.clientFD, ok, sizeof(ok));
    [self pumpWSReceive];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    if (self.state == TGWStateRelayWS || self.state == TGWStateClosed) {
        if (error) TGWLog(@"ws closed: %@", error);
        [self closeAll];
    } else if (error) {
        TGWLog(@"ws failed before open (%@), falling back to direct TCP", error);
        [self connectDirectTCP];
    }
}

- (void)pumpWSReceive {
    __weak typeof(self) weakSelf = self;
    [self.wsTask receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message, NSError *error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.state != TGWStateRelayWS) return;
        if (error) { TGWLog(@"ws recv error: %@", error); [strongSelf closeAll]; return; }
        NSData *data = message.type == NSURLSessionWebSocketMessageTypeData ? message.data
                     : [message.string dataUsingEncoding:NSUTF8StringEncoding];
        if (data) WriteAll(strongSelf.clientFD, data.bytes, data.length);
        [strongSelf pumpWSReceive];
    }];
}

// -------------------- direct TCP fallback --------------------

- (void)connectDirectTCP {
    if (self.state == TGWStateClosed) return;
    [self.wsTask cancel];
    self.wsTask = nil;

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { [self closeAll]; return; }
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(self.destPort);
    if (inet_pton(AF_INET, self.destHost.UTF8String, &addr.sin_addr) != 1) {
        TGWLog(@"cannot resolve %@ for direct TCP", self.destHost);
        close(fd);
        [self closeAll];
        return;
    }
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        TGWLog(@"direct TCP connect failed: %s", strerror(errno));
        close(fd);
        [self closeAll];
        return;
    }
    self.remoteFD = fd;
    SetNonBlocking(fd);
    self.state = TGWStateRelayTCP;
    uint8_t ok[10] = {0x05, 0x00, 0x00, 0x01, 0,0,0,0, 0,0};
    WriteAll(self.clientFD, ok, sizeof(ok));

    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    self.remoteReadSrc = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0, q);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.remoteReadSrc, ^{ [weakSelf remoteReadable]; });
    dispatch_resume(self.remoteReadSrc);
}

- (void)remoteReadable {
    uint8_t buf[8192];
    ssize_t n = read(self.remoteFD, buf, sizeof(buf));
    if (n <= 0) {
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return;
        [self closeAll];
        return;
    }
    WriteAll(self.clientFD, buf, (size_t)n);
}

@end

// ---------------------------------------------------------------------
// Listener
// ---------------------------------------------------------------------

static NSMutableSet<SocksSession *> *gSessions;

static void AcceptLoop(int listenFD) {
    while (1) {
        struct sockaddr_in cli; socklen_t len = sizeof(cli);
        int fd = accept(listenFD, (struct sockaddr *)&cli, &len);
        if (fd < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) return;
            if (errno == EINTR) continue;
            return;
        }
        int one = 1;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        SocksSession *s = [[SocksSession alloc] initWithFD:fd];
        s.onClose = ^(SocksSession *sess) { [gSessions removeObject:sess]; };
        [gSessions addObject:s];
        [s start];
    }
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        gConfig = [TGWSConfig load];
        gSessions = [NSMutableSet new];

        int listenFD = socket(AF_INET, SOCK_STREAM, 0);
        if (listenFD < 0) { perror("socket"); return 1; }
        int reuse = 1;
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

        struct sockaddr_in addr = {0};
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK); // 127.0.0.1 only
        addr.sin_port = htons(gConfig.port);

        if (bind(listenFD, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
            TGWLog(@"bind() failed on port %d: %s", gConfig.port, strerror(errno));
            return 1;
        }
        if (listen(listenFD, 128) != 0) {
            TGWLog(@"listen() failed: %s", strerror(errno));
            return 1;
        }
        SetNonBlocking(listenFD);
        TGWLog(@"tgwsproxyd listening on 127.0.0.1:%d", gConfig.port);

        dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, listenFD, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(src, ^{ AcceptLoop(listenFD); });
        dispatch_resume(src);

        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
