package dev.kammcs.cloudflare_realtime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The ring screen's monogram (docs/design.md §4.8, The caller's picture). */
class CallerMonogramTest {
    private fun initials(name: String) = CallerMonogram.initials(name)

    @Test
    fun firstAndLastWords() {
        assertEquals("AL", initials("Ada Lovelace"))
        assertEquals("AL", initials("  ada   king  lovelace "))
        assertEquals("A", initials("ada"))
        assertEquals("D", initials("demo-caller"))
        assertEquals("A", initials("ada@example.com"))
        assertEquals("AT", initials("Ada\tTuring"))
    }

    @Test
    fun leadingPunctuationIsSkipped() {
        assertEquals("AL", initials("(Ada) \"Lovelace\""))
        assertEquals("DS", initials("Dr. Smith"))
        assertEquals("A", initials("Ada -"))
    }

    @Test
    fun noLettersMeansNoInitials() {
        assertEquals("", initials(""))
        assertEquals("", initials("   "))
        assertEquals("", initials("+1 555 0100"))
        assertEquals("", initials("(555) 0100"))
        assertEquals("", initials("..."))
    }

    @Test
    fun graphemesNotUtf16Units() {
        // Letters with combining marks stay whole, and upper-case.
        assertEquals("ÉM", initials("émile Martin"))
        assertEquals("ÉM", initials("émile martin"))
        // Outside the BMP (a surrogate pair): one letter.
        assertEquals("𝐀", initials("𝐀bc"))
        // Emoji: with a skin tone, joined (ZWJ), a flag.
        assertEquals("👋🏽", initials("👋🏽"))
        assertEquals("👩‍💻A", initials("👩‍💻 Ada"))
        assertEquals("🇩🇪", initials("🇩🇪"))
    }

    @Test
    fun otherScripts() {
        // Chinese, Japanese and Korean names, usually written without spaces.
        assertEquals("王", initials("王小明"))
        assertEquals("山太", initials("山田 太郎"))
        assertEquals("김", initials("김민준"))
        // Right to left: logical order (the text renders it).
        assertEquals("עכ", initials("עדה כהן"))
        assertEquals("ΑΛ", initials("αδα λαβλεις"))
        assertEquals("ИП", initials("Иван Петров"))
    }

    @Test
    fun colourIsStableAndInRange() {
        for (name in listOf("Ada", "Ada Lovelace", "王小明", "+1 555 0100", "")) {
            val index = CallerMonogram.colorIndex(name, 10)
            assertTrue(index in 0 until 10)
            assertEquals(index, CallerMonogram.colorIndex(name, 10))
            assertEquals(index, CallerMonogram.colorIndex("  $name ", 10))
        }
        // Pinned, so that a caller keeps their colour across releases.
        assertEquals(9, CallerMonogram.colorIndex("Ada", 10))
        assertEquals(0, CallerMonogram.colorIndex("Ada Lovelace", 10))
        assertEquals(7, CallerMonogram.colorIndex("Demo caller", 10))
        assertEquals(1, CallerMonogram.colorIndex("王小明", 10))
        assertEquals(0, CallerMonogram.colorIndex("anything", 1))
    }

    @Test
    fun coloursSpread() {
        val used = (0 until 200).map { CallerMonogram.colorIndex("Caller $it", 10) }.toSet()
        assertEquals(10, used.size)
    }
}
