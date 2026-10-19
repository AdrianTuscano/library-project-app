package com.shelverhelper.app

import android.content.Intent
import android.os.Bundle
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.isVisible
import com.google.firebase.auth.FirebaseAuth
import com.shelverhelper.app.databinding.ActivityHomeBinding

class HomeActivity : AppCompatActivity() {

    private lateinit var b: ActivityHomeBinding

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        b = ActivityHomeBinding.inflate(layoutInflater)
        setContentView(b.root)

        b.topBar.profileButton.isVisible = true
        b.topBar.profileButton.setSafeClickListener {
            startActivity(Intent(this, ProfileActivity::class.java))
        }
        b.sampleButton.setSafeClickListener {
            b.shelfInput.setText(SAMPLE_SHELF)
            b.shelfInput.setSelection(0)
            showError(null)
        }
        b.sortButton.setSafeClickListener { sort() }
    }

    override fun onStart() {
        super.onStart()
        val user = FirebaseAuth.getInstance().currentUser
        if (user == null) {
            // Signed out (or the account was removed): back to the sign-in screen.
            startActivity(
                Intent(this, LoginActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
            )
            finish()
            return
        }
        val name = user.displayName?.takeIf { it.isNotBlank() }
            ?: user.email?.substringBefore('@')
            ?: "friend"
        TopBar.bind(b.topBar, title = "Shelver Helper", subtitle = "Hello, $name")
    }

    private fun sort() {
        val books = ShelfParser.parse(b.shelfInput.text.toString())
        when {
            books.size < 2 -> return showError("Type at least two books first, one on each line.")
            books.size > ShelfParser.MAX_BOOKS ->
                return showError("That is a lot of books! Try ${ShelfParser.MAX_BOOKS} or fewer at a time.")
        }
        showError(null)
        ShelfStore.books = books
        FirebaseAuth.getInstance().currentUser?.let { ProfileRepository.countShelf(it.uid) }
        startActivity(Intent(this, ResultsActivity::class.java))
    }

    private fun showError(message: String?) {
        b.errorRow.isVisible = message != null
        b.errorText.text = message
    }

    companion object {
        private const val SAMPLE_SHELF = """The Hobbit by J.R.R. Tolkien
Charlotte's Web by E.B. White
Hatchet by Gary Paulsen
Holes by Louis Sachar
Number the Stars by Lois Lowry
Matilda by Roald Dahl
Bridge to Terabithia by Katherine Paterson
Birds of North America | Chandler Robbins | 598.2
Wonder by R.J. Palacio (checked out)
The Giver by Lois Lowry"""
    }
}
