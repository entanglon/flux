import Foundation

// MARK: - Damerau-Levenshtein Typo & Fuzzy Matching

struct DamerauLevenshtein {
    
    /// Max allowed edit distance scaled by query length
    static func maxDistance(forQueryLength length: Int) -> Int {
        switch length {
        case 0...3: return 0 // No fuzzy matching for short ambiguous queries
        case 4...6: return 1 // 1 typo / transposition / insertion / deletion
        default:    return 2 // 2 edits maximum (capped to avoid candidate explosion)
        }
    }
    
    /// Computes true Damerau-Levenshtein distance (including adjacent character transpositions)
    static func distance(_ s1: String, _ s2: String) -> Int {
        let a = Array(s1.utf16)
        let b = Array(s2.utf16)
        let n = a.count
        let m = b.count
        
        if n == 0 { return m }
        if m == 0 { return n }
        
        // Fast path for identical strings
        if a == b { return 0 }
        
        var d = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        
        for i in 0...n { d[i][0] = i }
        for j in 0...m { d[0][j] = j }
        
        for i in 1...n {
            for j in 1...m {
                let cost = (a[i - 1] == b[j - 1]) ? 0 : 1
                
                d[i][j] = min(
                    d[i - 1][j] + 1,       // deletion
                    d[i][j - 1] + 1,       // insertion
                    d[i - 1][j - 1] + cost // substitution
                )
                
                // Transposition check
                if i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1] {
                    d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
                }
            }
        }
        
        return d[n][m]
    }
}
