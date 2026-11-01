import Foundation

@MainActor
enum WechatCaptureRecovery {
    static func run(_ attempt: (Int) async throws -> (Data, CaptureResourceReport?)) async throws -> Data {
        for round in 0...2 {
            try Task.checkCancellation()
            let (data, report) = try await attempt(round)
            try Task.checkCancellation()
            guard round < 2, let report, !report.issues.isEmpty,
                  report.issues.allSatisfy({ $0.reason == .archiveMissing && $0.nodeID != nil }) else { return data }
        }
        throw CaptureError.invalidPackage
    }

    /// Reload only failed DOM image nodes, at most three at once. The original
    /// source address and source session stay in WebKit, never in the job store.
    static let retryScript = #"""
    const entries=(globalThis.__readeckResources||new Map());
    const selected=Array.from(new Set(ids)).map(id=>entries.get(id)).filter(Boolean);
    for(let offset=0;offset<selected.length;offset+=3) {
      if(globalThis.__readeckCaptureAbort)throw new Error('采集已取消');
      await Promise.all(selected.slice(offset,offset+3).map(({node,source})=>new Promise(resolve=>{
        let timer;
        const end=()=>{clearTimeout(timer);node.removeEventListener('load',end);node.removeEventListener('error',end);resolve();};
        node.addEventListener('load',end,{once:true});node.addEventListener('error',end,{once:true});
        timer=setTimeout(end,5000);
        node.removeAttribute('src');node.src=source;
      })));
    }
    return selected.length;
    """#
}
