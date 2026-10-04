package dev.kammcs.cloudflare_realtime

import java.text.BreakIterator
import java.util.Locale

/**
 * The caller's monogram on the ring screen (docs/design.md §4.8, The
 * caller's picture): its initials and its colour. Pure Kotlin, no Android
 * classes, so the JVM unit tests (`android/src/test`) cover it.
 */
internal object CallerMonogram {
    /**
     * Up to two initials of [name]: the first character of its first word
     * and of its last, upper-cased (`Ada Lovelace` → `AL`, `ada` → `A`).
     *
     * Characters are graphemes, not UTF-16 units, so an emoji (with its
     * skin tone or joiners), a flag, a letter with combining marks or a
     * character outside the BMP stays whole. A word's leading punctuation
     * and symbols are skipped (`(Ada)` → `A`, `+1 555` → nothing), emoji
     * excepted. A name without letters or emoji (a phone number) has no
     * initials: `""`, for which the ring screen draws a person instead.
     */
    fun initials(name: String): String {
        if (!name.codePoints().anyMatch(::isInitial)) return ""
        val firsts = name.trim().split(WHITESPACE).mapNotNull(::firstInitial)
        val picked = when (firsts.size) {
            0 -> return ""
            1 -> firsts
            else -> listOf(firsts.first(), firsts.last())
        }
        return picked.joinToString("") { it.uppercase(Locale.ROOT) }
    }

    /**
     * Which of [count] colours [name] gets: the same for the same name,
     * on every device and every run (FNV-1a over its code points; not
     * [String.hashCode], whose spread over a few buckets is poor).
     */
    fun colorIndex(name: String, count: Int): Int {
        require(count > 0) { "count must be positive" }
        var hash = 0x811C9DC5.toInt()
        name.trim().codePoints().forEach {
            hash = (hash xor it) * 0x01000193
        }
        return Math.floorMod(hash, count)
    }

    private val WHITESPACE = Regex("\\s+")

    /** The word's first grapheme that is a letter, a digit or an emoji. */
    private fun firstInitial(word: String): String? {
        if (word.isEmpty()) return null
        val graphemes = BreakIterator.getCharacterInstance(Locale.ROOT)
        graphemes.setText(word)
        var start = graphemes.first()
        var end = graphemes.next()
        while (end != BreakIterator.DONE) {
            val first = word.codePointAt(start)
            if (isInitial(first) || Character.isDigit(first)) return word.substring(start, end)
            start = end
            end = graphemes.next()
        }
        return null
    }

    /** A letter (any script) or a symbol such as an emoji or a flag. */
    private fun isInitial(codePoint: Int): Boolean =
        Character.isLetter(codePoint) || Character.getType(codePoint) == Character.OTHER_SYMBOL.toInt()
}
