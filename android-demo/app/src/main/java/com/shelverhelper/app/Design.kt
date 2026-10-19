package com.shelverhelper.app

import android.view.HapticFeedbackConstants
import android.view.View
import android.os.SystemClock

object Palette {
    val spines = intArrayOf(
        0xFF5C5348.toInt(), 0xFF7D5411.toInt(), 0xFF3F4A52.toInt(), 0xFF8C3A2B.toInt(),
        0xFF2D2B2B.toInt(), 0xFF6B6350.toInt(), 0xFF9B7232.toInt(), 0xFF4A4740.toInt(),
        0xFF7A6A55.toInt(), 0xFF605D5D.toInt(),
    )
    val gold = 0xFFB68235.toInt()
    val goldText = 0xFF7D5411.toInt()
    val rust = 0xFF8C3A2B.toInt()
    val green = 0xFF3F6E4D.toInt()
    val nonFiction = 0xFF3F4A52.toInt()
    val shelfLine = 0xFFCFC9C2.toInt()
    val spineLabel = 0xFFF7F2EA.toInt()
    val white = 0xFFFFFFFF.toInt()

    fun spine(position: Int): Int = spines[(position - 1) % spines.size]

    fun fix(fix: Fix): Int = when (fix) {
        Fix.CIRCULATION -> rust
        Fix.NON_FICTION -> nonFiction
        else -> goldText
    }
}

/** Spine size in dp, derived from the title/author so every book keeps its own look. */
fun spineWidth(title: String): Int {
    val hash = title.fold(0) { a, c -> a xor c.code }
    return 32 + (Math.abs(hash) % 20)
}

fun spineHeight(title: String, author: String): Int {
    val hash = (author + title).fold(0) { a, c -> a xor c.code }
    return 130 + (Math.abs(hash) % 70)
}

private var lastTap = 0L

/** Drops taps within 450ms of the last accepted one so mashing a button can't navigate twice. */
fun View.setSafeClickListener(block: () -> Unit) {
    setOnClickListener { v ->
        val now = SystemClock.elapsedRealtime()
        if (now - lastTap < 450) return@setOnClickListener
        lastTap = now
        v.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
        block()
    }
}
