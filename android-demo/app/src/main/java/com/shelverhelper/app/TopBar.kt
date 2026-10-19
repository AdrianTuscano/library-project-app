package com.shelverhelper.app

import androidx.core.view.isVisible
import com.shelverhelper.app.databinding.ViewTopBarBinding

object TopBar {
    /** Header with a labelled Back button (when [backLabel] is set), a title and an optional subtitle. */
    fun bind(
        bar: ViewTopBarBinding,
        title: String,
        subtitle: String? = null,
        backLabel: String? = null,
        onBack: (() -> Unit)? = null,
    ) {
        bar.title.text = title
        bar.subtitle.text = subtitle
        bar.subtitle.isVisible = subtitle != null
        bar.backButton.isVisible = backLabel != null
        if (backLabel != null) {
            bar.backLabel.text = backLabel
            bar.backButton.contentDescription = backLabel
            bar.backButton.setSafeClickListener { onBack?.invoke() }
        }
    }
}
