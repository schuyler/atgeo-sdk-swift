import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
let c = URLSessionConfiguration.ephemeral
c.urlCache = nil; c.requestCachePolicy = .reloadIgnoringLocalCacheData; c.httpCookieStorage = nil
let s = URLSession(configuration: c)
let sem = DispatchSemaphore(value: 0)
let task = s.dataTask(with: URLRequest(url: URL(string: "http://127.0.0.1:18081/xrpc/x?a=1")!)) { d, r, e in
    print("status:", (r as? HTTPURLResponse)?.statusCode ?? -1, "error:", e.map { "\($0)" } ?? "nil", "body:", d.map { String(decoding: $0, as: UTF8.self) } ?? "nil")
    sem.signal()
}
task.resume(); sem.wait()
