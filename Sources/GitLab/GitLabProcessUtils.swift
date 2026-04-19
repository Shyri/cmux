import Foundation

/// Drains a process's stdout and stderr pipes concurrently to avoid deadlocks
/// when either stream fills the kernel pipe buffer (typically 16–64 KB on
/// macOS). Reading them sequentially can hang glab if it tries to flush the
/// unread stream while we block on the other.
func drainPipesInParallel(stdout: Pipe, stderr: Pipe) -> (Data, Data) {
    var outData = Data()
    var errData = Data()
    let group = DispatchGroup()
    let queue = DispatchQueue(label: "gitlab.pipe.drain", attributes: .concurrent)

    group.enter()
    queue.async {
        outData = stdout.fileHandleForReading.readDataToEndOfFile()
        group.leave()
    }

    group.enter()
    queue.async {
        errData = stderr.fileHandleForReading.readDataToEndOfFile()
        group.leave()
    }

    group.wait()
    return (outData, errData)
}
