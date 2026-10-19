package com.shelverhelper.app

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.util.Patterns
import android.view.inputmethod.InputMethodManager
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.isVisible
import com.google.firebase.FirebaseNetworkException
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.auth.FirebaseAuthInvalidCredentialsException
import com.google.firebase.auth.FirebaseAuthInvalidUserException
import com.google.firebase.auth.FirebaseAuthUserCollisionException
import com.google.firebase.auth.FirebaseAuthWeakPasswordException
import com.google.firebase.auth.FirebaseUser
import com.google.firebase.auth.UserProfileChangeRequest
import com.shelverhelper.app.databinding.ActivityLoginBinding

class LoginActivity : AppCompatActivity() {

    private lateinit var b: ActivityLoginBinding
    private val auth get() = FirebaseAuth.getInstance()
    private var creating = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        b = ActivityLoginBinding.inflate(layoutInflater)
        setContentView(b.root)
        creating = savedInstanceState?.getBoolean("creating") ?: false

        b.submitButton.setOnClickListener { submit() }
        b.toggleButton.setOnClickListener {
            creating = !creating
            showError(null)
            render()
        }
        render()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putBoolean("creating", creating)
    }

    override fun onStart() {
        super.onStart()
        if (auth.currentUser != null) goHome()
    }

    private fun render() {
        b.formTitle.text = if (creating) "Create your account" else "Sign in"
        b.nameLayout.isVisible = creating
        b.submitButton.text = if (creating) "Create account" else "Sign in"
        b.toggleButton.text = if (creating) "I already have an account" else "New here? Create an account"
        b.passwordLayout.helperText = if (creating) "At least 6 letters or numbers" else null
    }

    private fun submit() {
        val name = b.nameInput.text.toString().trim()
        val email = b.emailInput.text.toString().trim()
        val password = b.passwordInput.text.toString()

        when {
            creating && name.isEmpty() -> return showError("Please type your name.")
            !Patterns.EMAIL_ADDRESS.matcher(email).matches() ->
                return showError("That email doesn't look right. It should look like name@example.com.")
            password.length < 6 -> return showError("Your password needs at least 6 letters or numbers.")
        }
        showError(null)
        hideKeyboard()
        setBusy(true)

        if (creating) {
            auth.createUserWithEmailAndPassword(email, password).addOnCompleteListener { task ->
                val user = if (task.isSuccessful) task.result?.user else null
                if (user != null) onAccountCreated(user, name, email) else fail(task.exception)
            }
        } else {
            auth.signInWithEmailAndPassword(email, password).addOnCompleteListener { task ->
                if (task.isSuccessful) goHome() else fail(task.exception)
            }
        }
    }

    private fun onAccountCreated(user: FirebaseUser, name: String, email: String) {
        val nameRequest = UserProfileChangeRequest.Builder().setDisplayName(name).build()
        user.updateProfile(nameRequest).addOnCompleteListener {
            ProfileRepository.create(user.uid, name, email) { goHome() }
        }
    }

    private fun fail(e: Exception?) {
        setBusy(false)
        showError(
            when (e) {
                is FirebaseAuthWeakPasswordException -> "That password is too easy to guess. Try a longer one."
                is FirebaseAuthUserCollisionException -> "There is already an account with that email. Try signing in."
                is FirebaseAuthInvalidUserException,
                is FirebaseAuthInvalidCredentialsException -> "The email or password is not right. Please try again."
                is FirebaseNetworkException -> "No internet. Check your connection and try again."
                else -> "Something went wrong. Please try again."
            }
        )
    }

    private fun showError(message: String?) {
        b.errorRow.isVisible = message != null
        b.errorText.text = message
    }

    private fun setBusy(busy: Boolean) {
        b.progress.isVisible = busy
        b.submitButton.isEnabled = !busy
        b.toggleButton.isEnabled = !busy
    }

    private fun hideKeyboard() {
        val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
        imm.hideSoftInputFromWindow(b.root.windowToken, 0)
    }

    private fun goHome() {
        startActivity(Intent(this, HomeActivity::class.java))
        finish()
    }
}
