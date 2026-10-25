import Foundation

/// Finding by a few words: a text as a search compares it (lowercased, accents aside, each word
/// cut to its stem), and how well one word matches a thing's fields of words. The templates are
/// found this way (`SayForms.search`), and so are the requests a client refers to.
public enum APISearch {
    /// Words a question has that say nothing about what's wanted.
    static let stopWords: Set<String> = [
        "a", "an", "the", "to", "of", "for", "and", "or", "in", "on", "at", "by", "with", "from", "into", "about",
        "i", "me", "my", "we", "our", "you", "your", "it", "its", "this", "that", "these", "those", "there",
        "is", "are", "be", "was", "do", "does", "can", "could", "would", "should", "will", "want", "wants", "need",
        "how", "what", "which", "when", "where", "who", "why", "please", "some", "any", "all", "one", "get", "api",
    ]

    /// The words of a text as a search compares them: lowercased, accents aside, split at
    /// anything that isn't a letter or a digit, each cut to its stem ("notes", "noted": note).
    public static func words(_ text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return folded.split { !($0.isLetter || $0.isNumber) }.map { stem(String($0)) }.filter { !$0.isEmpty }
    }

    /// A word without its ending ("birthdays" birthday, "categories" category, "scheduled" and
    /// "schedules" schedul): not English, only close enough that the same word written two ways
    /// compares the same. The plural first, then -ing or -ed, then a last e.
    static func stem(_ w: String) -> String {
        var w = w
        if w.count > 4, w.hasSuffix("ies") { w = String(w.dropLast(3)) + "y" }
        else if w.count > 4, ["ses", "xes", "ches", "shes"].contains(where: w.hasSuffix) { w = String(w.dropLast(2)) }
        else if w.count > 3, w.hasSuffix("s"), !w.hasSuffix("ss") { w = String(w.dropLast()) }
        var cut = false
        if w.count > 5, w.hasSuffix("ing") { w = String(w.dropLast(3)); cut = true }
        else if w.count > 5, w.hasSuffix("ed") { w = String(w.dropLast(2)); cut = true }
        // "running" runn, "stopped" stopp: one of a doubled last letter (run, stop).
        if cut, let last = w.last, w.dropLast().last == last, !"aeiouls".contains(last) { w.removeLast() }
        if w.count > 4, w.hasSuffix("e") { w = String(w.dropLast()) }
        return w
    }

    /// The words to look for: the question's, without the ones that say nothing (unless that's
    /// all it has), each once.
    public static func query(_ q: String) -> [String] {
        // A letter alone ("what's": s) says nothing; a digit might.
        let all = words(q).filter { $0.count > 1 || $0.first?.isNumber == true }
        let kept = all.filter { !stopWords.contains($0) }
        var seen: Set<String> = []
        return (kept.isEmpty ? all : kept).filter { seen.insert($0).inserted }
    }

    /// One thing to find, as fields of words, each with its weight.
    struct Doc {
        var fields: [(words: Set<String>, weight: Int)]
        /// Words it's not for (a route's `!open` tags): a search with one puts it lower.
        var notFor: Set<String> = []

        /// How well one word matches: the weight of the best field it's in, or (a word of three
        /// letters or more) a field word it begins, one less.
        func score(_ q: String) -> Int {
            var best = 0
            for f in fields {
                if f.words.contains(q) { best = max(best, f.weight) }
                else if q.count >= 3, f.words.contains(where: { $0.count > q.count && $0.hasPrefix(q) }) { best = max(best, f.weight - 1) }
            }
            return best
        }
    }

    static func set(_ texts: [String]) -> Set<String> { Set(texts.flatMap(words)) }

    /// Words the examples that ship with the app are found by, beyond what their headers say
    /// (their files can't change without making them look edited): what someone would ask for.
    static let exampleTags: [String: String] = [
        "browser/open-page.sh": "open go goto navigate visit load url address website link browse web page",
        "browser/google.sh": "google search web online internet look up question answer browse open",
        "browser/site-search.sh": "search web website site youtube amazon github wikipedia reddit online",
        "browser/browser.sh": "open navigate url javascript",
        "browser/find-tab.sh": "switch tab go",
        "browser/youtube.sh": "video search watch",
        "utilities/weather.py": "forecast rain temperature",
    ]

}
