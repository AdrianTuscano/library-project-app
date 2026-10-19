package com.shelverhelper.app

import java.util.Locale

data class Book(
    val position: Int,
    val title: String,
    val author: String,
    val callNumber: String? = null,
    val checkedOut: Boolean = false,
)

/** What to do with one book, most urgent first. */
enum class Fix { CIRCULATION, NON_FICTION, MOVE, NONE }

data class SortItem(
    val book: Book,
    val currentSlot: Int,
    /** Physical spot it belongs in; null when it leaves the shelf. */
    val targetSlot: Int?,
    val fix: Fix,
) {
    val leaves: Boolean get() = fix == Fix.CIRCULATION || fix == Fix.NON_FICTION
}

/** Libraries on Biblionix's Apollo platform (same list as the iOS app's settings). */
enum class CatalogLibrary(val label: String) {
    GEORGETOWN("Georgetown Public Library"),
    LIBERTY_HILL("Liberty Hill Public Library"),
    TAYLOR("Taylor Public Library"),
    HUTTO("Hutto Public Library"),
    PFLUGERVILLE("Pflugerville Public Library"),
    WELLS_BRANCH("Wells Branch Community Library"),
}

/** The shelf the person typed, shared between the results screens. */
object ShelfStore {
    var books: List<Book> = emptyList()
}

object ShelfParser {
    const val MAX_BOOKS = 60

    private val numbering = Regex("^\\s*\\d+[.)]\\s+")
    private val checkedOutTag = Regex("\\s*\\(checked out\\)\\s*$", RegexOption.IGNORE_CASE)
    private val byWord = Regex("\\s+by\\s+", RegexOption.IGNORE_CASE)

    /**
     * One book per line. Accepted forms:
     *   Title by Author
     *   Title | Author | Call number
     * A trailing "(checked out)" marks the book as checked out.
     */
    fun parse(text: String): List<Book> {
        val books = mutableListOf<Book>()
        for (raw in text.lines()) {
            var line = numbering.replace(raw.trim(), "")
            val checkedOut = checkedOutTag.containsMatchIn(line)
            line = checkedOutTag.replace(line, "").trim()
            if (line.isEmpty()) continue

            val title: String
            var author = ""
            var callNumber: String? = null
            if (line.contains('|')) {
                val parts = line.split('|').map { it.trim() }
                title = parts[0]
                author = parts.getOrElse(1) { "" }
                callNumber = parts.getOrNull(2)?.ifEmpty { null }
            } else {
                // The last " by " wins, so "Stand by Me by Stephen King" splits correctly.
                val m = byWord.findAll(line).lastOrNull()
                if (m != null) {
                    title = line.substring(0, m.range.first).trim()
                    author = line.substring(m.range.last + 1).trim()
                } else {
                    title = line
                }
            }
            if (title.isEmpty()) continue
            books += Book(books.size + 1, title, author, callNumber, checkedOut)
        }
        return books
    }
}

object ShelfSorter {
    private val fictionPrefix = Regex("^J?F\\s+(.+)$")
    private val fictionStart = Regex("^J?F\\b")
    private val biographyPrefix = Regex("^BIO?\\s+(.+)$")
    private val deweyStart = Regex("^(\\d{3}\\.?\\d*)")

    fun lastName(author: String): String {
        val parts = author.trim().split(Regex("\\s+"))
        return parts.lastOrNull()?.uppercase(Locale.ROOT) ?: ""
    }

    fun deweyValue(callNumber: String?): Double? {
        if (callNumber == null) return null
        return deweyStart.find(callNumber)?.groupValues?.get(1)?.toDoubleOrNull()
    }

    private fun sortKey(b: Book): String {
        val cn = b.callNumber?.trim()?.uppercase(Locale.ROOT)
        if (!cn.isNullOrEmpty()) {
            fictionPrefix.find(cn)?.let { return it.groupValues[1] }
            biographyPrefix.find(cn)?.let { return it.groupValues[1] }
            deweyValue(b.callNumber)?.let {
                return String.format(Locale.US, "%.4f", it).padStart(12, '0')
            }
            return cn
        }
        return lastName(b.author)
    }

    private fun isNonFiction(b: Book): Boolean {
        val cn = b.callNumber?.trim()?.uppercase(Locale.ROOT)
        if (!cn.isNullOrEmpty()) return !fictionStart.containsMatchIn(cn)
        return deweyValue(b.callNumber) != null
    }

    /**
     * Checked-out books go to circulation; non-fiction goes to its own section.
     * The fiction that stays is ordered A–Z, and each book's target is the
     * physical spot currently held by the book that should be there.
     */
    fun compute(books: List<Book>): List<SortItem> {
        val staying = books.indices.filter { !books[it].checkedOut && !isNonFiction(books[it]) }
        val sorted = staying.sortedBy { sortKey(books[it]) }
        val targetByIndex = HashMap<Int, Int>()
        sorted.forEachIndexed { k, idx -> targetByIndex[idx] = staying[k] + 1 }

        return books.mapIndexed { i, b ->
            when {
                b.checkedOut -> SortItem(b, i + 1, null, Fix.CIRCULATION)
                isNonFiction(b) -> SortItem(b, i + 1, null, Fix.NON_FICTION)
                else -> {
                    val target = targetByIndex.getValue(i)
                    SortItem(b, i + 1, target, if (target != i + 1) Fix.MOVE else Fix.NONE)
                }
            }
        }
    }
}
