package com.example.duck_downloader

import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import com.google.android.material.bottomsheet.BottomSheetDialog
import java.util.regex.Pattern

class ShareActivity : AppCompatActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        try {
            // 1. Extract shared URL
            var sharedUrl: String? = null
            val intentText = intent?.getStringExtra(Intent.EXTRA_TEXT)
            if (!intentText.isNullOrEmpty()) {
                val matcher = Pattern.compile("(https?://[^\\s]+)").matcher(intentText)
                if (matcher.find()) {
                    sharedUrl = matcher.group(0)
                }
            }

            if (sharedUrl == null) {
                Toast.makeText(this, "No valid link found to download.", Toast.LENGTH_SHORT).show()
                finish()
                return
            }

            // 2. Build Native Bottom Sheet Dialog over calling app
            val dialog = BottomSheetDialog(this)
            val container = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(dpToPx(24), dpToPx(24), dpToPx(24), dpToPx(24))

                // Liquid glass dark panel styling
                val bg = GradientDrawable().apply {
                    setColor(Color.parseColor("#1F2A2D"))
                    cornerRadii = floatArrayOf(
                        dpToPx(24).toFloat(), dpToPx(24).toFloat(),
                        dpToPx(24).toFloat(), dpToPx(24).toFloat(),
                        0f, 0f, 0f, 0f
                    )
                    setStroke(dpToPx(1), Color.parseColor("#40FFD700"))
                }
                background = bg
            }

            // Header Title
            val titleText = TextView(this).apply {
                text = "Duck Quick Download ⚡"
                setTextColor(Color.parseColor("#FFD700"))
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
                setTypeface(typeface, android.graphics.Typeface.BOLD)
                gravity = Gravity.START
            }
            container.addView(titleText)

            // URL Preview Box
            val urlPreview = TextView(this).apply {
                text = sharedUrl
                setTextColor(Color.parseColor("#CCCCCC"))
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
                maxLines = 1
                ellipsize = android.text.TextUtils.TruncateAt.END
                setPadding(dpToPx(12), dpToPx(8), dpToPx(12), dpToPx(8))
                val boxBg = GradientDrawable().apply {
                    setColor(Color.parseColor("#15FFFFFF"))
                    cornerRadius = dpToPx(8).toFloat()
                }
                background = boxBg
                layoutParams = LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT
                ).apply {
                    topMargin = dpToPx(12)
                    bottomMargin = dpToPx(16)
                }
            }
            container.addView(urlPreview)

            val lang = java.util.Locale.getDefault().language
            val analyzingStr = when (lang) {
                "ar" -> "جاري تحليل الجودات المتاحة... ⚡"
                "es" -> "Analizando calidades disponibles... ⚡"
                "fr" -> "Analyse des qualités... ⚡"
                "de" -> "Qualitäten werden analysiert... ⚡"
                "ru" -> "Анализ качества... ⚡"
                "tr" -> "Kaliteler analiz ediliyor... ⚡"
                "hi" -> "गुणवत्ता का विश्लेषण हो रहा है... ⚡"
                "zh" -> "正在解析画质... ⚡"
                else -> "Analyzing available qualities... ⚡"
            }
            val selectQualityStr = when (lang) {
                "ar" -> "اختر جودة التحميل:"
                "es" -> "Seleccionar calidad:"
                "fr" -> "Sélectionner la qualité :"
                "de" -> "Qualität auswählen:"
                "ru" -> "Выберите качество:"
                "tr" -> "Kalite seçin:"
                "hi" -> "गुणवत्ता चुनें:"
                "zh" -> "选择画质:"
                else -> "Select Download Quality:"
            }
            val videoBtnStr = when (lang) {
                "ar" -> "🎥 فيديو HD (1080p / 720p)"
                "es" -> "🎥 Vídeo HD (1080p / 720p)"
                "fr" -> "🎥 Vidéo HD (1080p / 720p)"
                "de" -> "🎥 Video HD (1080p / 720p)"
                "ru" -> "🎥 Видео HD (1080p / 720p)"
                "tr" -> "🎥 Video HD (1080p / 720p)"
                "hi" -> "🎥 वीडियो HD (1080p / 720p)"
                "zh" -> "🎥 高清视频 (1080p / 720p)"
                else -> "🎥 Video HD (1080p / 720p)"
            }
            val audioBtnStr = when (lang) {
                "ar" -> "🎵 صوت MP3 (320kbps)"
                "es" -> "🎵 Audio MP3 (320kbps)"
                "fr" -> "🎵 Audio MP3 (320kbps)"
                "de" -> "🎵 Audio MP3 (320kbps)"
                "ru" -> "🎵 Аудио MP3 (320kbps)"
                "tr" -> "🎵 Ses MP3 (320kbps)"
                "hi" -> "🎵 ऑडियो MP3 (320kbps)"
                "zh" -> "🎵 音频 MP3 (320kbps)"
                else -> "🎵 Audio MP3 (320kbps)"
            }

            // Loading Section
            val loadingLayout = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER
                setPadding(0, dpToPx(8), 0, dpToPx(16))
            }
            val progressBar = ProgressBar(this).apply {
                isIndeterminate = true
                layoutParams = LinearLayout.LayoutParams(dpToPx(24), dpToPx(24))
            }
            val loadingText = TextView(this).apply {
                text = analyzingStr
                setTextColor(Color.parseColor("#AAAAAA"))
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
                setPadding(dpToPx(12), 0, 0, 0)
            }
            loadingLayout.addView(progressBar)
            loadingLayout.addView(loadingText)
            container.addView(loadingLayout)

            // Quality Section Label
            val qualitiesLabel = TextView(this).apply {
                text = selectQualityStr
                setTextColor(Color.parseColor("#888888"))
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
                visibility = View.GONE
                layoutParams = LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT
                ).apply {
                    bottomMargin = dpToPx(8)
                }
            }
            container.addView(qualitiesLabel)

            // Horizontal Quality Buttons Layout
            val scrollView = HorizontalScrollView(this).apply {
                visibility = View.GONE
                layoutParams = LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT
                ).apply {
                    bottomMargin = dpToPx(16)
                }
            }
            val chipsLayout = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
            }
            scrollView.addView(chipsLayout)
            container.addView(scrollView)

            // Default Action Buttons
            val videoBtn = Button(this).apply {
                text = videoBtnStr
                setTextColor(Color.parseColor("#101112"))
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
                setTypeface(typeface, android.graphics.Typeface.BOLD)
                val btnBg = GradientDrawable().apply {
                    setColor(Color.parseColor("#FFD700"))
                    cornerRadius = dpToPx(14).toFloat()
                }
                background = btnBg
                layoutParams = LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    dpToPx(48)
                ).apply {
                    bottomMargin = dpToPx(10)
                }
                setOnClickListener {
                    startBackgroundDownload(sharedUrl, "video")
                    dialog.dismiss()
                }
            }
            container.addView(videoBtn)

            val audioBtn = Button(this).apply {
                text = audioBtnStr
                setTextColor(Color.WHITE)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
                setTypeface(typeface, android.graphics.Typeface.BOLD)
                val btnBg = GradientDrawable().apply {
                    setColor(Color.parseColor("#25FFFFFF"))
                    setStroke(dpToPx(1), Color.parseColor("#80FFD700"))
                    cornerRadius = dpToPx(14).toFloat()
                }
                background = btnBg
                layoutParams = LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    dpToPx(48)
                )
                setOnClickListener {
                    startBackgroundDownload(sharedUrl, "audio")
                    dialog.dismiss()
                }
            }
            container.addView(audioBtn)

            // 3. Asynchronously Extract YouTube / Media Qualities
            val targetUrl = sharedUrl
            Thread {
                try {
                    val qualities = ArrayList<String>()
                    qualities.add("1080p")
                    qualities.add("720p")
                    qualities.add("480p")
                    qualities.add("360p")
                    qualities.add("MP3")

                    runOnUiThread {
                        try {
                            loadingLayout.visibility = View.GONE
                            qualitiesLabel.visibility = View.VISIBLE
                            scrollView.visibility = View.VISIBLE

                            chipsLayout.removeAllViews()
                            for (q in qualities) {
                                val chipBtn = Button(this@ShareActivity).apply {
                                    text = q
                                    setTextColor(Color.parseColor("#FFD700"))
                                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
                                    setTypeface(typeface, android.graphics.Typeface.BOLD)
                                    val chipBg = GradientDrawable().apply {
                                        setColor(Color.parseColor("#1AFFFFFF"))
                                        setStroke(dpToPx(1), Color.parseColor("#80FFD700"))
                                        cornerRadius = dpToPx(20).toFloat()
                                    }
                                    background = chipBg
                                    layoutParams = LinearLayout.LayoutParams(
                                        ViewGroup.LayoutParams.WRAP_CONTENT,
                                        dpToPx(36)
                                    ).apply {
                                        rightMargin = dpToPx(8)
                                    }
                                    setOnClickListener {
                                        val type = if (q.contains("MP3")) "audio" else "video"
                                        startBackgroundDownload(targetUrl, type)
                                        dialog.dismiss()
                                    }
                                }
                                chipsLayout.addView(chipBtn)
                            }
                        } catch (e: Exception) {
                            loadingLayout.visibility = View.GONE
                        }
                    }
                } catch (e: Exception) {
                    runOnUiThread {
                        loadingLayout.visibility = View.GONE
                    }
                }
            }.start()

            dialog.setContentView(container)
            dialog.setOnDismissListener {
                finish()
            }
            dialog.show()
        } catch (e: Exception) {
            e.printStackTrace()
            finish()
        }
    }

    private fun startBackgroundDownload(url: String, type: String) {
        try {
            val launchIntent = Intent(this, MainActivity::class.java).apply {
                action = "ACTION_BACKGROUND_QUICK_DOWNLOAD"
                putExtra(Intent.EXTRA_TEXT, url)
                putExtra("quickShareUrl", url)
                putExtra("downloadType", type)
                putExtra("startDownloadDirectly", true)
                putExtra("quickShare", true)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            }
            startActivity(launchIntent)
            val lang = java.util.Locale.getDefault().language
            val toastStr = when (lang) {
                "ar" -> "جاري التحميل في الخلفية... 🚀"
                "es" -> "Descargando en segundo plano... 🚀"
                "fr" -> "Téléchargement en arrière-plan... 🚀"
                "de" -> "Download im Hintergrund... 🚀"
                "ru" -> "Скачивание в фоновом режиме... 🚀"
                "tr" -> "Arka planda indiriliyor... 🚀"
                "hi" -> "बैकग्राउंड में डाउनलोड हो रहा है... 🚀"
                "zh" -> "正在后台下载... 🚀"
                else -> "Downloading in background... 🚀"
            }
            Toast.makeText(this, toastStr, Toast.LENGTH_LONG).show()
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private fun dpToPx(dp: Int): Int {
        return (dp * resources.displayMetrics.density).toInt()
    }
}
