package com.shelverhelper.app

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Typeface
import android.text.TextUtils
import android.util.AttributeSet
import android.view.MotionEvent
import android.view.View
import androidx.core.content.ContextCompat
import androidx.core.graphics.drawable.DrawableCompat
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * Draws a row of book spines on a shelf.
 *  - BROWSE: tap a spine to select it (gold border, lifted, status dot).
 *  - SORT: spines show where each book should move, with arcs, arrows and badges.
 * Put it inside a HorizontalScrollView; it is as wide as its books need.
 */
class ShelfView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : View(context, attrs) {

    enum class Mode { BROWSE, SORT }

    var onSelect: ((Int) -> Unit)? = null

    var selected: Int = 0
        set(value) {
            field = value
            invalidate()
        }

    private var items: List<SortItem> = emptyList()
    private var mode = Mode.BROWSE
    private var geometry: Geometry? = null

    private val dp = resources.displayMetrics.density

    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
    }
    private val text = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Palette.spineLabel
        textAlign = Paint.Align.CENTER
        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        textSize = 13 * dp
    }
    private val badgeText = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Palette.white
        typeface = Typeface.create("sans-serif-medium", Typeface.BOLD)
        textSize = 15 * dp
    }

    private val cartIcon = ContextCompat.getDrawable(context, R.drawable.ic_cart)!!.mutate()
    private val upIcon = ContextCompat.getDrawable(context, R.drawable.ic_up)!!.mutate()
    private val forwardIcon = ContextCompat.getDrawable(context, R.drawable.ic_arrow_forward)!!.mutate()
    private val checkIcon = ContextCompat.getDrawable(context, R.drawable.ic_check)!!.mutate()

    private class Geometry(
        val xs: FloatArray,
        val widths: FloatArray,
        val heights: FloatArray,
        val shelfY: Float,
        val maxTop: Float,
        val totalWidth: Float,
    ) {
        fun top(i: Int) = shelfY - heights[i]
        fun centerX(i: Int) = xs[i] + widths[i] / 2
    }

    private val gap get() = 8 * dp
    private val shelfH get() = 8 * dp
    private val sortArcZone get() = 72 * dp
    private val sortBadgeZone get() = 30 * dp
    private val sortBottomPad get() = 6 * dp

    fun setItems(list: List<SortItem>, mode: Mode) {
        items = list
        this.mode = mode
        geometry = null
        contentDescription = "Shelf with ${list.size} books. " +
            if (mode == Mode.BROWSE) "Use the Previous and Next buttons to choose a book." else ""
        requestLayout()
        invalidate()
    }

    fun centerX(index: Int): Float = (geometry ?: compute(measuredHeight.toFloat())).centerX(index)

    private fun compute(h: Float): Geometry {
        val n = items.size
        val left = 16 * dp
        val widths = FloatArray(n) { spineWidth(items[it].book.title) * dp }
        val rawH = FloatArray(n) { spineHeight(items[it].book.title, items[it].book.author) * dp }
        val rawMax = rawH.maxOrNull() ?: 0f

        val sort = mode == Mode.SORT
        val above = if (sort) sortArcZone + sortBadgeZone else 12 * dp
        val below = if (sort) sortBottomPad else 0f
        val scale = if (rawMax > 0) {
            ((h - above - shelfH - below) / rawMax).coerceIn(if (sort) 0.4f else 0.45f, 1f)
        } else 1f
        val heights = FloatArray(n) { rawH[it] * scale }

        val xs = FloatArray(n)
        var cx = left
        for (i in 0 until n) {
            xs[i] = cx
            cx += widths[i] + gap
        }
        val shelfY = h - shelfH - below
        return Geometry(xs, widths, heights, shelfY, shelfY - rawMax * scale, cx - gap + 20 * dp)
    }

    private fun geo(): Geometry = geometry ?: compute(height.toFloat()).also { geometry = it }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        geometry = null
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val defaultH = ((if (mode == Mode.SORT) 300 else 230) * dp).toInt()
        val h = if (MeasureSpec.getMode(heightMeasureSpec) == MeasureSpec.EXACTLY) {
            MeasureSpec.getSize(heightMeasureSpec)
        } else defaultH
        val needed = compute(h.toFloat()).totalWidth.toInt()
        val w = if (MeasureSpec.getMode(widthMeasureSpec) == MeasureSpec.EXACTLY) {
            max(needed, MeasureSpec.getSize(widthMeasureSpec))
        } else needed
        setMeasuredDimension(w, h)
    }

    override fun onDraw(canvas: Canvas) {
        if (items.isEmpty()) return
        val g = geo()
        if (mode == Mode.SORT) {
            drawArcs(canvas, g)
            drawBadges(canvas, g)
        }
        for (i in items.indices) drawSpine(canvas, g, i)

        fill.color = Palette.shelfLine
        canvas.drawRect(0f, g.shelfY, width.toFloat(), g.shelfY + shelfH, fill)
    }

    private fun drawSpine(canvas: Canvas, g: Geometry, i: Int) {
        val item = items[i]
        val isSelected = mode == Mode.BROWSE && i == selected
        val lift = if (isSelected) 6 * dp else 0f
        val left = g.xs[i]
        val right = left + g.widths[i]
        val top = g.top(i) - lift
        val bottom = g.shelfY - lift

        fill.color = Palette.spine(item.book.position)
        canvas.drawRect(left, top, right, bottom, fill)

        val borderColor = when {
            isSelected -> Palette.gold
            mode == Mode.SORT && item.fix != Fix.NONE -> Palette.fix(item.fix)
            else -> null
        }
        if (borderColor != null) {
            val w = (if (isSelected) 3.5f else 3f) * dp
            stroke.color = borderColor
            stroke.strokeWidth = w
            canvas.drawRect(left + w / 2, top + w / 2, right - w / 2, bottom - w / 2, stroke)
        }

        // Title, reading bottom-to-top, centred in the space below any status dot.
        val padTop = if (mode == Mode.BROWSE) 30 * dp else 8 * dp
        val padBottom = 8 * dp
        val area = (bottom - padBottom) - (top + padTop)
        if (area > 20 * dp) {
            val slot = if (mode == Mode.BROWSE) item.book.position else item.currentSlot
            val label = TextUtils.ellipsize(
                "$slot  ${item.book.title}", text, area, TextUtils.TruncateAt.END
            ).toString()
            val cx = (left + right) / 2
            val cy = (top + padTop + bottom - padBottom) / 2
            val fm = text.fontMetrics
            canvas.save()
            canvas.rotate(-90f, cx, cy)
            canvas.drawText(label, cx, cy - (fm.ascent + fm.descent) / 2, text)
            canvas.restore()
        }

        if (mode == Mode.BROWSE) {
            // Status is shown by icon as well as color: cart = checked out, check = on the shelf.
            val cx = (left + right) / 2
            val cy = top + 4 * dp + 11 * dp
            fill.color = if (item.book.checkedOut) Palette.rust else Palette.green
            canvas.drawCircle(cx, cy, 11 * dp, fill)
            drawIcon(canvas, if (item.book.checkedOut) cartIcon else checkIcon, cx, cy, 14 * dp)
        }
    }

    private fun drawIcon(canvas: Canvas, icon: android.graphics.drawable.Drawable, cx: Float, cy: Float, size: Float) {
        val half = (size / 2).toInt()
        icon.setBounds((cx - half).toInt(), (cy - half).toInt(), (cx + half).toInt(), (cy + half).toInt())
        DrawableCompat.setTint(icon, Palette.white)
        icon.draw(canvas)
    }

    private fun drawBadges(canvas: Canvas, g: Geometry) {
        val badgeH = 26 * dp
        val top = g.maxTop - sortBadgeZone + 2 * dp
        for (i in items.indices) {
            val item = items[i]
            if (item.fix == Fix.NONE) continue
            val left = g.xs[i] - 6 * dp
            val right = g.xs[i] + g.widths[i] + 6 * dp
            val color = Palette.fix(item.fix)
            fill.color = color
            canvas.drawRoundRect(RectF(left, top, right, top + badgeH), 6 * dp, 6 * dp, fill)

            val cx = (left + right) / 2
            val cy = top + badgeH / 2
            when (item.fix) {
                Fix.CIRCULATION -> drawIcon(canvas, cartIcon, cx, cy, 18 * dp)
                Fix.NON_FICTION -> drawIcon(canvas, upIcon, cx, cy, 18 * dp)
                else -> {
                    val label = "${item.targetSlot}"
                    val labelW = badgeText.measureText(label)
                    val iconSize = 14 * dp
                    val total = iconSize + 2 * dp + labelW
                    val startX = cx - total / 2
                    drawIcon(canvas, forwardIcon, startX + iconSize / 2, cy, iconSize)
                    val fm = badgeText.fontMetrics
                    canvas.drawText(label, startX + iconSize + 2 * dp, cy - (fm.ascent + fm.descent) / 2, badgeText)
                }
            }
        }
    }

    private fun drawArcs(canvas: Canvas, g: Geometry) {
        stroke.strokeWidth = 2.5f * dp
        for (i in items.indices) {
            val item = items[i]
            if (item.fix == Fix.NONE) continue
            val x1 = g.centerX(i)
            val y1 = g.top(i)
            val color = Palette.fix(item.fix)
            stroke.color = color
            fill.color = color

            if (item.leaves) {
                canvas.drawLine(x1, y1, x1, y1 - 56 * dp, stroke)
                canvas.drawPath(arrowHead(x1, y1 - 61 * dp, up = true), fill)
            } else {
                val j = (item.targetSlot ?: continue) - 1
                if (j < 0 || j >= items.size) continue
                val x2 = g.centerX(j)
                val y2 = g.top(j)
                val lift = min(40 * dp + abs(x2 - x1) * 0.09f, 78 * dp)
                val path = Path().apply {
                    moveTo(x1, y1)
                    cubicTo(x1, y1 - lift, x2, y2 - lift, x2, y2)
                }
                canvas.drawPath(path, stroke)
                canvas.drawPath(arrowHead(x2, y2 + 5 * dp, up = false), fill)
            }
        }
    }

    /** Triangle with its tip at (x, y): pointing up for section arrows, down onto a spine for arcs. */
    private fun arrowHead(x: Float, y: Float, up: Boolean): Path = Path().apply {
        if (up) {
            moveTo(x, y)
            lineTo(x - 5 * dp, y + 11 * dp)
            lineTo(x + 5 * dp, y + 11 * dp)
        } else {
            moveTo(x, y)
            lineTo(x - 5 * dp, y - 11 * dp)
            lineTo(x + 5 * dp, y - 11 * dp)
        }
        close()
    }

    private fun hit(x: Float): Int {
        val g = geo()
        var best = -1
        var bestDist = Float.MAX_VALUE
        for (i in items.indices) {
            // At least a 48dp-wide target even for narrow spines.
            val half = max((g.widths[i] + gap) / 2, 24 * dp)
            val d = abs(x - g.centerX(i))
            if (d <= half && d < bestDist) {
                best = i
                bestDist = d
            }
        }
        return best
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (mode != Mode.BROWSE || items.isEmpty()) return super.onTouchEvent(event)
        when (event.actionMasked) {
            MotionEvent.ACTION_UP -> {
                val i = hit(event.x)
                if (i >= 0) {
                    onSelect?.invoke(i)
                    performClick()
                }
            }
        }
        return true
    }

    override fun performClick(): Boolean {
        super.performClick()
        return true
    }
}
