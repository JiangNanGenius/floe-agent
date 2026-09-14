// Desktop qualification of the actual Objective-C service boundary, not an iOS claim.
#import "../../FloeApp/Execution/FloeCPythonBridge.m"
NSString *FloeTLSCertificateBundle(void) { return nil; }
NSDictionary *FloeTLSEnvironment(void) { return @{}; }
int main(int argc, const char **argv) {
    @autoreleasepool {
        Py_Initialize();
        if (PySys_AddAuditHook(FloePythonAuditHook, NULL) != 0) return 2;
        FloeAuditHookInstalled = 1;
        PyEval_SaveThread();
        NSString *root = [NSString stringWithUTF8String:argv[1]];
        NSDictionary *context = @{@"environmentID": @"test-owner", @"workingDirectory": root};
        NSString *json = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:context options:0 error:nil] encoding:NSUTF8StringEncoding];
        NSString *script = @"from http.server import HTTPServer, BaseHTTPRequestHandler\nfrom pathlib import Path\nclass Handler(BaseHTTPRequestHandler):\n def do_GET(self):\n  self.send_response(200)\n  self.end_headers()\n  self.wfile.write(b'bridge-service')\n def log_message(self,*args): pass\ns=HTTPServer(('127.0.0.1',0),Handler)\nPath('port').write_text(str(s.server_address[1]))\ntry: s.serve_forever(poll_interval=0.05)\nfinally: s.server_close()\n";
        NSDictionary *started = [FloeCPythonBridge startService:script contextJSON:json environmentID:@"test-owner" maxOutputBytes:1024];
        NSString *identifier = started[@"serviceID"];
        if (!identifier) { NSLog(@"start failed %@", started); return 3; }
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
        NSString *portPath = [root stringByAppendingPathComponent:@"port"];
        while (![[NSFileManager defaultManager] fileExistsAtPath:portPath] && deadline.timeIntervalSinceNow > 0) [NSThread sleepForTimeInterval:0.02];
        NSString *port = [NSString stringWithContentsOfFile:portPath encoding:NSUTF8StringEncoding error:nil];
        if (!port.length) { NSLog(@"service failed %@", [FloeCPythonBridge serviceStatus:identifier environmentID:@"test-owner"]); return 4; }
        // Use an independent URLSession to verify the actual listener.
        for (int i=0;i<3;i++) {
            dispatch_semaphore_t signal = dispatch_semaphore_create(0);
            __block BOOL okay = NO;
            NSURL *url = [NSURL URLWithString:[@"http://127.0.0.1:" stringByAppendingFormat:@"%@/",port]];
            [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                okay = !error && [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] isEqual:@"bridge-service"];
                dispatch_semaphore_signal(signal);
            }] resume];
            if (dispatch_semaphore_wait(signal, dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)) || !okay) return 5;
        }
        if (![[FloeCPythonBridge stopService:identifier environmentID:@"wrong-owner"][@"status"] isEqual:@"notFound"]) return 6;
        if (![FloeCPythonBridge hasActiveServices:@"test-owner"]) return 7;
        NSDictionary *stopped = [FloeCPythonBridge stopService:identifier environmentID:@"test-owner"];
        if (![stopped[@"status"] isEqual:@"stopped"] || [FloeCPythonBridge hasActiveServices:@"test-owner"]) { NSLog(@"stop failed %@",stopped); return 8; }
        puts("native bridge: HTTP x3, ownership and interpreter shutdown passed");
        return 0;
    }
}
