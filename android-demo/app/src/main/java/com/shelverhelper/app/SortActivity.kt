package com.shelverhelper.app

import android.content.Intent
import android.content.res.ColorStateList
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.isVisible
import com.shelverhelper.app.databinding.ActivitySortBinding
import com.shelverhelper.app.databinding.ItemActionBinding

class SortActivity : AppCompatActivity() {

    private lateinit var b: ActivitySortBinding

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        b = ActivitySortBinding.inflate(layoutInflater)
        setContentView(b.root)

        val books = ShelfStore.books
        if (books.isEmpty()) {
            finish()
            return
        }
        val items = ShelfSorter.compute(books)
        val todo = items.filter { it.fix != Fix.NONE }.sortedBy { it.fix.ordinal }
        val cartCount = todo.count { it.leaves }

        TopBar.bind(
            b.topBar,
            title = "What to do",
            subtitle = if (todo.isEmpty()) "All books are in order"
            else "${todo.size} of ${books.size} books need attention",
            backLabel = "My shelf",
        ) { finish() }

        b.shelf.setItems(items, ShelfView.Mode.SORT)

        b.cartHeader.isVisible = cartCount > 0
        b.cartHeader.text = "Put $cartCount ${if (cartCount == 1) "book" else "books"} on your cart"
        b.emptyBlock.isVisible = todo.isEmpty()

        val inflater = LayoutInflater.from(this)
        todo.forEachIndexed { i, item ->
            if (i > 0) b.actions.addView(divider())
            b.actions.addView(actionRow(inflater, item))
        }

        b.againButton.setSafeClickListener {
            // Back to the home screen, clearing the results screens on top of it.
            startActivity(
                Intent(this, HomeActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP)
            )
            finish()
        }
    }

    private fun actionRow(inflater: LayoutInflater, item: SortItem): View {
        val row = ItemActionBinding.inflate(inflater, b.actions, false)
        val color = Palette.fix(item.fix)
        val instruction = when (item.fix) {
            Fix.CIRCULATION ->
                "The library says this book is checked out, but it is here. " +
                    "Put it on your cart and take it to circulation."
            Fix.NON_FICTION -> "This is non-fiction. Put it on your cart for the non-fiction shelves."
            Fix.MOVE -> "Move it from spot ${item.currentSlot} to spot ${item.targetSlot}."
            Fix.NONE -> ""
        }

        row.circle.backgroundTintList = ColorStateList.valueOf(color)
        when (item.fix) {
            Fix.CIRCULATION -> row.circleIcon.setImageResource(R.drawable.ic_cart)
            Fix.NON_FICTION -> row.circleIcon.setImageResource(R.drawable.ic_up)
            else -> {
                row.circleIcon.isVisible = false
                row.circleNumber.isVisible = true
                row.circleNumber.text = item.currentSlot.toString()
            }
        }
        row.title.text = "${item.currentSlot}. ${item.book.title}"
        row.instruction.text = instruction
        row.instruction.setTextColor(color)
        row.root.contentDescription = "Book ${item.currentSlot}, ${item.book.title}. $instruction"
        return row.root
    }

    private fun divider(): View = View(this).apply {
        layoutParams = android.widget.LinearLayout.LayoutParams(
            android.widget.LinearLayout.LayoutParams.MATCH_PARENT, 1
        )
        setBackgroundColor(getColor(R.color.divider))
    }
}
