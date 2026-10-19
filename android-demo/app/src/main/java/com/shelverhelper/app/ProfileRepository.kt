package com.shelverhelper.app

import com.google.firebase.firestore.FieldValue
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.SetOptions

data class Profile(
    val displayName: String,
    val email: String,
    val library: CatalogLibrary,
    val shelvesSorted: Long,
)

/**
 * One document per person at users/{uid}. firestore.rules lets a signed-in
 * person read and write only the document whose id is their own uid.
 */
object ProfileRepository {
    private val users get() = FirebaseFirestore.getInstance().collection("users")

    fun create(uid: String, name: String, email: String, done: (Exception?) -> Unit) {
        val data = hashMapOf<String, Any>(
            "displayName" to name,
            "email" to email,
            "library" to CatalogLibrary.GEORGETOWN.name,
            "shelvesSorted" to 0L,
            "createdAt" to FieldValue.serverTimestamp(),
        )
        users.document(uid).set(data).addOnCompleteListener { done(it.exception) }
    }

    fun load(uid: String, fallbackName: String, email: String, done: (Result<Profile>) -> Unit) {
        users.document(uid).get().addOnCompleteListener { task ->
            val doc = if (task.isSuccessful) task.result else null
            if (doc == null) {
                done(Result.failure(task.exception ?: Exception("Could not load profile")))
                return@addOnCompleteListener
            }
            done(
                Result.success(
                    Profile(
                        displayName = doc.getString("displayName") ?: fallbackName,
                        email = email,
                        library = CatalogLibrary.values()
                            .firstOrNull { it.name == doc.getString("library") }
                            ?: CatalogLibrary.GEORGETOWN,
                        shelvesSorted = doc.getLong("shelvesSorted") ?: 0L,
                    )
                )
            )
        }
    }

    fun save(uid: String, profile: Profile, done: (Exception?) -> Unit) {
        val data = hashMapOf<String, Any>(
            "displayName" to profile.displayName,
            "email" to profile.email,
            "library" to profile.library.name,
        )
        users.document(uid).set(data, SetOptions.merge()).addOnCompleteListener { done(it.exception) }
    }

    /** Best effort: the count is a nicety, so a failure here is ignored. */
    fun countShelf(uid: String) {
        users.document(uid).update("shelvesSorted", FieldValue.increment(1))
    }
}
