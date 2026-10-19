package com.shelverhelper.app

import android.content.Intent
import android.os.Bundle
import android.widget.ArrayAdapter
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.isVisible
import com.google.firebase.FirebaseNetworkException
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.auth.UserProfileChangeRequest
import com.shelverhelper.app.databinding.ActivityProfileBinding

class ProfileActivity : AppCompatActivity() {

    private lateinit var b: ActivityProfileBinding
    private val user get() = FirebaseAuth.getInstance().currentUser
    private var loaded = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        b = ActivityProfileBinding.inflate(layoutInflater)
        setContentView(b.root)

        TopBar.bind(b.topBar, title = "Your profile", backLabel = "Home") { finish() }

        val labels = CatalogLibrary.values().map { it.label }
        b.libraryInput.setAdapter(ArrayAdapter(this, android.R.layout.simple_list_item_1, labels))

        b.saveButton.setSafeClickListener { save() }
        b.signOutButton.setSafeClickListener { signOut() }
        load()
    }

    private fun load() {
        val u = user ?: return signOut()
        b.emailValue.text = u.email
        setBusy(true)
        ProfileRepository.load(u.uid, u.displayName.orEmpty(), u.email.orEmpty()) { result ->
            setBusy(false)
            result.onSuccess { p ->
                loaded = true
                b.nameInput.setText(p.displayName)
                b.libraryInput.setText(p.library.label, false)
                b.shelvesValue.text = p.shelvesSorted.toString()
                showStatus(null, ok = true)
            }.onFailure {
                // Still let them edit and save; the save will surface any real problem.
                b.nameInput.setText(u.displayName.orEmpty())
                b.libraryInput.setText(CatalogLibrary.GEORGETOWN.label, false)
                showStatus("We could not load your saved details.", ok = false)
            }
        }
    }

    private fun save() {
        val u = user ?: return signOut()
        val name = b.nameInput.text.toString().trim()
        if (name.isEmpty()) return showStatus("Please type your name.", ok = false)
        if (name.length > 60) return showStatus("That name is too long. Use 60 letters or fewer.", ok = false)

        val library = CatalogLibrary.values().firstOrNull { it.label == b.libraryInput.text.toString() }
            ?: CatalogLibrary.GEORGETOWN
        val profile = Profile(name, u.email.orEmpty(), library, 0L)

        setBusy(true)
        ProfileRepository.save(u.uid, profile) { error ->
            setBusy(false)
            if (error == null) {
                u.updateProfile(UserProfileChangeRequest.Builder().setDisplayName(name).build())
                showStatus("Saved", ok = true)
            } else {
                showStatus(
                    if (error is FirebaseNetworkException) "No internet. Check your connection and try again."
                    else "We could not save. Please try again.",
                    ok = false,
                )
            }
        }
    }

    private fun signOut() {
        FirebaseAuth.getInstance().signOut()
        ShelfStore.books = emptyList()
        startActivity(
            Intent(this, LoginActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        )
        finish()
    }

    private fun setBusy(busy: Boolean) {
        b.progress.isVisible = busy
        b.saveButton.isEnabled = !busy
    }

    /** A saved/error line with an icon, so the result never depends on color alone. */
    private fun showStatus(message: String?, ok: Boolean) {
        b.statusRow.isVisible = message != null
        b.statusText.text = message
        val color = getColor(if (ok) R.color.green else R.color.rust)
        b.statusText.setTextColor(color)
        b.statusIcon.setImageResource(if (ok) R.drawable.ic_check else R.drawable.ic_warning)
        b.statusIcon.setColorFilter(color)
    }
}
