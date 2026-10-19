package com.shelverhelper.app

import android.content.Intent
import android.os.Bundle
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.isVisible
import com.shelverhelper.app.databinding.ActivityResultsBinding

class ResultsActivity : AppCompatActivity() {

    private lateinit var b: ActivityResultsBinding
    private var items: List<SortItem> = emptyList()
    private var index = 0

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        b = ActivityResultsBinding.inflate(layoutInflater)
        setContentView(b.root)

        val books = ShelfStore.books
        if (books.isEmpty()) {
            finish()
            return
        }
        items = ShelfSorter.compute(books)
        index = (savedInstanceState?.getInt("index") ?: 0).coerceIn(0, items.size - 1)

        TopBar.bind(
            b.topBar,
            title = "Your shelf",
            subtitle = if (books.size == 1) "1 book" else "${books.size} books",
            backLabel = "New shelf",
        ) { finish() }

        b.shelf.setItems(items, ShelfView.Mode.BROWSE)
        b.shelf.onSelect = { select(it) }
        b.prevButton.setSafeClickListener { select(index - 1) }
        b.nextButton.setSafeClickListener { select(index + 1) }
        b.whatToDoButton.setSafeClickListener {
            startActivity(Intent(this, SortActivity::class.java))
        }
        b.againButton.setSafeClickListener { finish() }

        select(index, scroll = false)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putInt("index", index)
    }

    private fun select(i: Int, scroll: Boolean = true) {
        index = i.coerceIn(0, items.size - 1)
        val book = items[index].book
        b.shelf.selected = index

        if (scroll) {
            b.shelfScroll.post {
                val target = (b.shelf.centerX(index) - b.shelfScroll.width / 2f).toInt()
                b.shelfScroll.smoothScrollTo(target.coerceAtLeast(0), 0)
            }
        }

        b.counter.text = "${index + 1} of ${items.size}"
        b.prevButton.isEnabled = index > 0
        b.nextButton.isEnabled = index < items.size - 1

        b.bookTitle.text = book.title
        b.bookAuthor.isVisible = book.author.isNotEmpty()
        b.bookAuthor.text = "by ${book.author}"

        val color = getColor(if (book.checkedOut) R.color.rust else R.color.green)
        b.statusIcon.setImageResource(if (book.checkedOut) R.drawable.ic_cart else R.drawable.ic_check)
        b.statusIcon.setColorFilter(color)
        b.statusWord.setTextColor(color)
        b.statusWord.text = if (book.checkedOut) "Checked out" else "On the shelf"
        b.statusSentence.text =
            if (book.checkedOut) "This book is marked as checked out, so it should not be here."
            else "This book is not marked as checked out."

        b.callBlock.isVisible = book.callNumber != null
        b.callValue.text = book.callNumber
    }
}
