package dev.kammcs.cloudflare_realtime

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ColorFilter
import android.graphics.ImageDecoder
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.drawable.Drawable
import android.net.Uri
import android.os.Build
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * The caller's picture on the ring screen and in the call's notification
 * (docs/design.md §4.8, The caller's picture): the app's image when it gave
 * one and it decodes, else a monogram.
 *
 * The image is a local `file://` or `content://` URI only: the package
 * never fetches from the network (apps download the picture first, into
 * their cache for example). It is decoded off the main thread, downsampled
 * to [SIZE_DP], cropped to a square, and given up on (the monogram shows)
 * when it fails or takes longer than [DECODE_TIMEOUT_MS].
 */
internal object CallerAvatar {
    private const val TAG = "cloudflare_realtime"

    /** The picture's diameter on the ring screen. */
    const val SIZE_DP = 120

    /** The picture's size in the notification (the system shows it smaller). */
    private const val NOTIFICATION_DP = 64

    /**
     * How long a call waits for its picture before Telecom gets it. A local
     * image decodes in milliseconds; a slow content provider doesn't hold
     * the ring back.
     */
    private const val DECODE_TIMEOUT_MS = 1000L

    private val io = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /**
     * The image at [uri], decoded for the ring screen, or `null` (logged)
     * when it isn't a local URI, can't be read or decoded, or is too slow.
     */
    suspend fun load(context: Context, uri: String): Bitmap? {
        val parsed = Uri.parse(uri)
        val scheme = parsed.scheme?.lowercase()
        if (scheme != "file" && scheme != "content") {
            Log.w(TAG, "Caller image ignored: only file:// and content:// URIs are read (got ${scheme ?: "no scheme"}:)")
            return null
        }
        val size = px(context, SIZE_DP)
        val decoding = io.async {
            try {
                decode(context, parsed, size)
            } catch (e: Throwable) {
                // An unreadable file, a format the platform can't decode, or
                // a picture too large for memory: the monogram shows.
                Log.w(TAG, "Caller image not decoded: $e")
                null
            }
        }
        val image = withTimeoutOrNull(DECODE_TIMEOUT_MS) { decoding.await() }
        if (image == null && !decoding.isCompleted) {
            Log.w(TAG, "Caller image not decoded within $DECODE_TIMEOUT_MS ms")
            decoding.cancel()
        }
        return image
    }

    /** [image] (else [initials] on [color]) at the notification's size. */
    fun notificationIcon(context: Context, image: Bitmap?, name: String): Bitmap {
        val size = px(context, NOTIFICATION_DP)
        if (image != null) return Bitmap.createScaledBitmap(image, size, size, true)
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        monogram(context, name).apply {
            setBounds(0, 0, size, size)
            draw(Canvas(bitmap))
        }
        return bitmap
    }

    /** [name]'s monogram: its initials on its colour. */
    fun monogram(context: Context, name: String) =
        MonogramDrawable(CallerMonogram.initials(name), color(context, name))

    /**
     * [name]'s colour, from the array `cloudflare_realtime_monogram_colors`
     * (apps can override it; its colours carry white text).
     */
    private fun color(context: Context, name: String): Int {
        val colors = context.resources.obtainTypedArray(R.array.cloudflare_realtime_monogram_colors)
        try {
            if (colors.length() == 0) return Color.DKGRAY
            return colors.getColor(CallerMonogram.colorIndex(name, colors.length()), Color.DKGRAY)
        } finally {
            colors.recycle()
        }
    }

    private fun px(context: Context, dp: Int) = (dp * context.resources.displayMetrics.density).roundToInt().coerceAtLeast(1)

    /**
     * Decodes [uri] so that its shorter side is about [size] (never more
     * than the image's own), then crops the middle square at [size].
     * ImageDecoder (Android 9+) applies the EXIF orientation.
     */
    private fun decode(context: Context, uri: Uri, size: Int): Bitmap? {
        val decoded = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            ImageDecoder.decodeBitmap(ImageDecoder.createSource(context.contentResolver, uri)) { decoder, info, _ ->
                // Software: a notification's icon is parcelled and scaled.
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                val width = info.size.width
                val height = info.size.height
                val scale = size.toFloat() / min(width, height)
                if (scale < 1f) {
                    decoder.setTargetSize(
                        max(1, (width * scale).roundToInt()),
                        max(1, (height * scale).roundToInt()),
                    )
                }
            }
        } else {
            val resolver = context.contentResolver
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
            var sample = 1
            while (min(bounds.outWidth, bounds.outHeight) / (sample * 2) >= size) sample *= 2
            val options = BitmapFactory.Options().apply { inSampleSize = sample }
            resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, options) }
        } ?: return null
        return square(decoded, size)
    }

    /** The middle square of [bitmap], scaled to cover [size] × [size]. */
    private fun square(bitmap: Bitmap, size: Int): Bitmap {
        val side = min(bitmap.width, bitmap.height)
        val left = (bitmap.width - side) / 2
        val top = (bitmap.height - side) / 2
        val out = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        Canvas(out).drawBitmap(
            bitmap,
            Rect(left, top, left + side, top + side),
            Rect(0, 0, size, size),
            Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG),
        )
        bitmap.recycle()
        return out
    }
}

/**
 * A circle of [color] with [initials] in white, centred and sized to the
 * bounds; a person's silhouette when there are no initials (a phone number).
 */
internal class MonogramDrawable(private val initials: String, private val color: Int) : Drawable() {
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = this@MonogramDrawable.color }
    private val ink = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        textAlign = Paint.Align.CENTER
        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
    }
    private val clip = Path()

    override fun draw(canvas: Canvas) {
        val box = bounds
        val diameter = min(box.width(), box.height()).toFloat()
        if (diameter <= 0f) return
        val cx = box.exactCenterX()
        val cy = box.exactCenterY()
        val radius = diameter / 2
        canvas.drawCircle(cx, cy, radius, fill)
        if (initials.isEmpty()) {
            // A head and shoulders, clipped to the circle.
            canvas.drawCircle(cx, cy - diameter * 0.1f, diameter * 0.17f, ink)
            clip.reset()
            clip.addCircle(cx, cy, radius, Path.Direction.CW)
            canvas.save()
            canvas.clipPath(clip)
            canvas.drawOval(
                RectF(cx - diameter * 0.32f, cy + diameter * 0.13f, cx + diameter * 0.32f, cy + diameter * 0.62f),
                ink,
            )
            canvas.restore()
            return
        }
        // Anything wide (two broad initials, a long grapheme) shrinks to
        // fit inside the circle.
        ink.textSize = diameter * 0.42f
        val width = ink.measureText(initials)
        if (width > diameter * 0.66f) ink.textSize *= diameter * 0.66f / width
        val metrics = ink.fontMetrics
        canvas.drawText(initials, cx, cy - (metrics.ascent + metrics.descent) / 2, ink)
    }

    override fun setAlpha(alpha: Int) {
        fill.alpha = alpha
        ink.alpha = alpha
        invalidateSelf()
    }

    override fun setColorFilter(colorFilter: ColorFilter?) {
        fill.colorFilter = colorFilter
        ink.colorFilter = colorFilter
        invalidateSelf()
    }

    @Deprecated("Deprecated in Java")
    override fun getOpacity(): Int = PixelFormat.TRANSLUCENT
}
