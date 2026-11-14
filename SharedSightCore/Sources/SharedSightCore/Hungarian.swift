import Foundation

/// Optimal assignment (Kuhn–Munkres, O(n^3)). Returns, for each row, the assigned column or -1.
enum Hungarian {
    static func solve(_ cost: [[Double]]) -> [Int] {
        let n = cost.count
        guard n > 0, let m = cost.first?.count, m > 0 else { return [Int](repeating: -1, count: n) }
        if n > m {
            // Transpose so that rows <= columns, then invert the mapping.
            var t = [[Double]](repeating: [Double](repeating: 0, count: n), count: m)
            for i in 0..<n { for j in 0..<m { t[j][i] = cost[i][j] } }
            let colToRow = solve(t)
            var res = [Int](repeating: -1, count: n)
            for (j, i) in colToRow.enumerated() where i >= 0 { res[i] = j }
            return res
        }
        var u = [Double](repeating: 0, count: n + 1), v = [Double](repeating: 0, count: m + 1)
        var p = [Int](repeating: 0, count: m + 1), way = [Int](repeating: 0, count: m + 1)
        for i in 1...n {
            p[0] = i
            var j0 = 0
            var minv = [Double](repeating: .infinity, count: m + 1)
            var used = [Bool](repeating: false, count: m + 1)
            repeat {
                used[j0] = true
                let i0 = p[j0]
                var delta = Double.infinity
                var j1 = 0
                for j in 1...m where !used[j] {
                    let cur = cost[i0 - 1][j - 1] - u[i0] - v[j]
                    if cur < minv[j] { minv[j] = cur; way[j] = j0 }
                    if minv[j] < delta { delta = minv[j]; j1 = j }
                }
                for j in 0...m {
                    if used[j] { u[p[j]] += delta; v[j] -= delta } else { minv[j] -= delta }
                }
                j0 = j1
            } while p[j0] != 0
            repeat {
                let j1 = way[j0]
                p[j0] = p[j1]
                j0 = j1
            } while j0 != 0
        }
        var res = [Int](repeating: -1, count: n)
        for j in 1...m where p[j] != 0 { res[p[j] - 1] = j - 1 }
        return res
    }
}
