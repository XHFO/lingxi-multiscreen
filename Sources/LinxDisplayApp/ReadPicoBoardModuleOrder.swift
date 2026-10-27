/// Resolve the target after removing the dragged card so moving down still means "before".
/// 先移除被拖动卡片再定位目标，前后方向的拖放都落在目标卡片之前。
enum ReadPicoBoardModuleOrder {
    static func moving(_ source: Int, before target: Int, in modules: [Int]) -> [Int] {
        guard source != target, let origin = modules.firstIndex(of: source), modules.contains(target) else { return modules }
        var result = modules
        result.remove(at: origin)
        guard let destination = result.firstIndex(of: target) else { return modules }
        result.insert(source, at: destination)
        return result
    }
}
