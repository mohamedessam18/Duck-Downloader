package com.example.duck_downloader

import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.text.TextUtils
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
import java.util.Locale
import java.util.concurrent.Executors
import java.util.regex.Pattern

/**
 * The sheet that appears over whatever app the link was shared from.
 *
 * The point is that Duck never comes to the foreground. The user is in
 * Facebook, taps share, picks a quality, and is still in Facebook — the
 * download runs in [DownloadService] behind them. That rules out booting a
 * Flutter engine here (over a second of black screen before anything appears),
 * so the qualities come from the backend over plain HTTP, from the same
 * `/api/extract` the app itself calls.
 *
 * Until this activity was registered in the manifest it could never launch,
 * and sharing a link opened the whole app instead.
 */
class ShareActivity : AppCompatActivity() {

    private val work = Executors.newSingleThreadExecutor()
    private var dialog: BottomSheetDialog? = null
    private var sharedUrl: String = ""
    private var meta: DuckShareApi.Meta? = null

    private lateinit var loadingRow: LinearLayout
    private lateinit var loadingText: TextView
    private lateinit var qualitiesLabel: TextView
    private lateinit var chipsScroller: HorizontalScrollView
    private lateinit var chipsRow: LinearLayout
    private lateinit var titleLine: TextView
    private lateinit var videoButton: Button
    private lateinit var audioButton: Button

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val url = firstUrlIn(intent)
        if (url == null) {
            Toast.makeText(this, str.noLink, Toast.LENGTH_SHORT).show()
            finish()
            return
        }
        sharedUrl = url

        dialog = BottomSheetDialog(this).apply {
            setContentView(buildSheet(url))
            setOnDismissListener { finish() }
            show()
        }

        loadQualities()
    }

    // ---- Extraction -----------------------------------------------------------

    /**
     * Asks the backend what this link actually offers.
     *
     * The old version of this screen faked it: a spinner, a fixed
     * 1080p/720p/480p/360p list that had nothing to do with the link, and four
     * buttons that all did the identical thing. A 480p-only clip offered 1080p
     * and quietly gave you 480p.
     */
    private fun loadQualities() {
        work.execute {
            try {
                val result = DuckShareApi.extract(this, sharedUrl)
                runOnUiThread { showQualities(result) }
            } catch (error: Exception) {
                runOnUiThread { showExtractionFailed(error.message) }
            }
        }
    }

    private fun showQualities(result: DuckShareApi.Meta) {
        meta = result
        loadingRow.visibility = View.GONE

        if (result.title.isNotBlank() && result.title != "Untitled") {
            titleLine.text = result.title
            titleLine.visibility = View.VISIBLE
        }

        val formats = result.videoQualities
        if (formats.isEmpty()) {
            // Audio-only source, or a backend that could not enumerate
            // streams. The two default buttons still work.
            return
        }

        chipsRow.removeAllViews()
        for (format in formats) {
            chipsRow.addView(
                chip(format.label) { startDownload("video", format.label) }
            )
        }
        result.audioQualities.firstOrNull()?.let { best ->
            chipsRow.addView(chip("MP3") { startDownload("audio", best.label) })
        }
        qualitiesLabel.visibility = View.VISIBLE
        chipsScroller.visibility = View.VISIBLE
    }

    private fun showExtractionFailed(message: String?) {
        loadingRow.visibility = View.GONE
        // The two default buttons stay live: the backend can fail to enumerate
        // formats and still download the link perfectly well at "Best".
        titleLine.text = message ?: str.extractFailed
        titleLine.setTextColor(Color.parseColor("#FF9B9B"))
        titleLine.visibility = View.VISIBLE
    }

    // ---- Starting the download ------------------------------------------------

    private fun startDownload(type: String, quality: String) {
        val snapshot = meta

        // Start the service first, while this activity is still on screen.
        //
        // Android 12 refuses startForegroundService once the app is in the
        // background, and dismissing the sheet finishes this activity — so
        // doing the network call here and starting the service afterwards put
        // the start on the wrong side of that rule. Every share on Android 12+
        // was refused while the toast happily said the download had begun.
        //
        // The service asks the backend itself now. Nothing here waits on the
        // network, so there is nothing to be wrong about.
        DownloadService.enqueue(
            context = applicationContext,
            url = sharedUrl,
            title = snapshot?.title ?: "Download",
            thumbnail = snapshot?.thumbnail,
            platform = snapshot?.platform ?: "Public source",
            type = type,
            quality = quality,
        )

        Toast.makeText(this, str.starting, Toast.LENGTH_SHORT).show()
        dialog?.dismiss()
    }

    private fun openInApp() {
        startActivity(
            Intent(this, MainActivity::class.java).apply {
                action = Intent.ACTION_SEND
                type = "text/plain"
                putExtra(Intent.EXTRA_TEXT, sharedUrl)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            }
        )
        dialog?.dismiss()
    }

    // ---- Sheet ----------------------------------------------------------------

    private fun buildSheet(url: String): View {
        val container = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(24), dp(20), dp(24), dp(24))
            background = GradientDrawable().apply {
                setColor(Color.parseColor("#1F2A2D"))
                cornerRadii = floatArrayOf(
                    dp(24).toFloat(), dp(24).toFloat(),
                    dp(24).toFloat(), dp(24).toFloat(),
                    0f, 0f, 0f, 0f,
                )
                setStroke(dp(1), Color.parseColor("#40FFD700"))
            }
        }

        container.addView(TextView(this).apply {
            text = "Duck Quick Download ⚡"
            setTextColor(Color.parseColor("#FFD700"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
            setTypeface(typeface, android.graphics.Typeface.BOLD)
        })

        titleLine = TextView(this).apply {
            setTextColor(Color.parseColor("#EEEEEE"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            maxLines = 2
            ellipsize = TextUtils.TruncateAt.END
            visibility = View.GONE
            layoutParams = rowParams(topMargin = dp(10))
        }
        container.addView(titleLine)

        container.addView(TextView(this).apply {
            text = url
            setTextColor(Color.parseColor("#CCCCCC"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
            setPadding(dp(12), dp(8), dp(12), dp(8))
            background = GradientDrawable().apply {
                setColor(Color.parseColor("#15FFFFFF"))
                cornerRadius = dp(8).toFloat()
            }
            layoutParams = rowParams(topMargin = dp(12), bottomMargin = dp(16))
        })

        loadingText = TextView(this).apply {
            text = str.analyzing
            setTextColor(Color.parseColor("#AAAAAA"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            setPadding(dp(12), 0, 0, 0)
        }
        loadingRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(4), 0, dp(16))
            addView(ProgressBar(this@ShareActivity).apply {
                isIndeterminate = true
                layoutParams = LinearLayout.LayoutParams(dp(22), dp(22))
            })
            addView(loadingText)
        }
        container.addView(loadingRow)

        qualitiesLabel = TextView(this).apply {
            text = str.selectQuality
            setTextColor(Color.parseColor("#888888"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
            visibility = View.GONE
            layoutParams = rowParams(bottomMargin = dp(8))
        }
        container.addView(qualitiesLabel)

        chipsRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        chipsScroller = HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false
            visibility = View.GONE
            addView(chipsRow)
            layoutParams = rowParams(bottomMargin = dp(16))
        }
        container.addView(chipsScroller)

        videoButton = Button(this).apply {
            text = str.videoButton
            setTextColor(Color.parseColor("#101112"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            background = GradientDrawable().apply {
                setColor(Color.parseColor("#FFD700"))
                cornerRadius = dp(14).toFloat()
            }
            layoutParams = rowParams(height = dp(48), bottomMargin = dp(10))
            setOnClickListener { startDownload("video", "Best") }
        }
        container.addView(videoButton)

        audioButton = Button(this).apply {
            text = str.audioButton
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            background = GradientDrawable().apply {
                setColor(Color.parseColor("#25FFFFFF"))
                setStroke(dp(1), Color.parseColor("#80FFD700"))
                cornerRadius = dp(14).toFloat()
            }
            layoutParams = rowParams(height = dp(48), bottomMargin = dp(10))
            setOnClickListener { startDownload("audio", "Best") }
        }
        container.addView(audioButton)

        container.addView(TextView(this).apply {
            text = str.openInApp
            setTextColor(Color.parseColor("#9FB4B8"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            gravity = Gravity.CENTER
            setPadding(0, dp(6), 0, dp(2))
            layoutParams = rowParams()
            setOnClickListener { openInApp() }
        })

        return container
    }

    private fun chip(label: String, onTap: () -> Unit): Button = Button(this).apply {
        text = label
        setTextColor(Color.parseColor("#FFD700"))
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
        setTypeface(typeface, android.graphics.Typeface.BOLD)
        isAllCaps = false
        background = GradientDrawable().apply {
            setColor(Color.parseColor("#1AFFFFFF"))
            setStroke(dp(1), Color.parseColor("#80FFD700"))
            cornerRadius = dp(20).toFloat()
        }
        layoutParams = LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT,
            dp(38),
        ).apply { rightMargin = dp(8) }
        setPadding(dp(16), 0, dp(16), 0)
        setOnClickListener { onTap() }
    }

    private fun rowParams(
        height: Int = ViewGroup.LayoutParams.WRAP_CONTENT,
        topMargin: Int = 0,
        bottomMargin: Int = 0,
    ) = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, height).apply {
        this.topMargin = topMargin
        this.bottomMargin = bottomMargin
    }

    // ---- Input ----------------------------------------------------------------

    /**
     * Pulls the first link out of whatever the other app sent.
     *
     * Facebook, X and Instagram all share "some caption text https://link"
     * rather than a bare URL, and `ACTION_SEND_MULTIPLE` arrives as a list.
     */
    private fun firstUrlIn(intent: Intent?): String? {
        if (intent == null) return null
        val candidates = mutableListOf<String>()
        intent.getStringExtra(Intent.EXTRA_TEXT)?.let { candidates.add(it) }
        intent.getStringExtra(Intent.EXTRA_SUBJECT)?.let { candidates.add(it) }
        intent.getStringArrayListExtra(Intent.EXTRA_TEXT)?.let { candidates.addAll(it) }
        intent.dataString?.let { candidates.add(it) }

        val pattern = Pattern.compile("(https?://[^\\s]+)")
        for (candidate in candidates) {
            val matcher = pattern.matcher(candidate)
            if (matcher.find()) return matcher.group(0)?.trimEnd('.', ',', ')')
        }
        return null
    }

    override fun onDestroy() {
        work.shutdownNow()
        super.onDestroy()
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    // ---- Copy -----------------------------------------------------------------

    private val str by lazy { Strings(Locale.getDefault().language) }

    private class Strings(language: String) {
        val analyzing = pick(
            language,
            en = "Reading the link...",
            ar = "بيقرأ اللينك...",
            es = "Leyendo el enlace...",
            fr = "Lecture du lien...",
            de = "Link wird gelesen...",
            ru = "Чтение ссылки...",
            tr = "Bağlantı okunuyor...",
            hi = "लिंक पढ़ा जा रहा है...",
            zh = "正在读取链接...",
        )
        val selectQuality = pick(
            language,
            en = "Select quality:", ar = "اختر الجودة:", es = "Selecciona calidad:",
            fr = "Choisir la qualité :", de = "Qualität wählen:", ru = "Выберите качество:",
            tr = "Kalite seçin:", hi = "गुणवत्ता चुनें:", zh = "选择画质：",
        )
        val videoButton = pick(
            language,
            en = "🎥 Video · best quality", ar = "🎥 فيديو · أعلى جودة",
            es = "🎥 Vídeo · mejor calidad", fr = "🎥 Vidéo · meilleure qualité",
            de = "🎥 Video · beste Qualität", ru = "🎥 Видео · лучшее качество",
            tr = "🎥 Video · en iyi kalite", hi = "🎥 वीडियो · सर्वोत्तम गुणवत्ता",
            zh = "🎥 视频 · 最佳画质",
        )
        val audioButton = pick(
            language,
            en = "🎵 Audio · MP3", ar = "🎵 صوت · MP3", es = "🎵 Audio · MP3",
            fr = "🎵 Audio · MP3", de = "🎵 Audio · MP3", ru = "🎵 Аудио · MP3",
            tr = "🎵 Ses · MP3", hi = "🎵 ऑडियो · MP3", zh = "🎵 音频 · MP3",
        )
        val openInApp = pick(
            language,
            en = "More options in Duck", ar = "خيارات أكتر في Duck",
            es = "Más opciones en Duck", fr = "Plus d'options dans Duck",
            de = "Mehr Optionen in Duck", ru = "Больше настроек в Duck",
            tr = "Duck'ta daha fazla seçenek", hi = "Duck में और विकल्प",
            zh = "在 Duck 中查看更多选项",
        )
        val starting = pick(
            language,
            en = "Downloading in the background 🚀", ar = "بينزّل في الخلفية 🚀",
            es = "Descargando en segundo plano 🚀", fr = "Téléchargement en arrière-plan 🚀",
            de = "Download im Hintergrund 🚀", ru = "Скачивание в фоне 🚀",
            tr = "Arka planda indiriliyor 🚀", hi = "बैकग्राउंड में डाउनलोड हो रहा है 🚀",
            zh = "正在后台下载 🚀",
        )
        val noLink = pick(
            language,
            en = "No link found to download.", ar = "مفيش لينك في اللي اتشيّر.",
            es = "No se encontró ningún enlace.", fr = "Aucun lien trouvé.",
            de = "Kein Link gefunden.", ru = "Ссылка не найдена.",
            tr = "Bağlantı bulunamadı.", hi = "कोई लिंक नहीं मिला।",
            zh = "未找到可下载的链接。",
        )
        val extractFailed = pick(
            language,
            en = "Could not read the qualities — the buttons below still work.",
            ar = "مقدرش يقرأ الجودات — الأزرار تحت لسه شغالة.",
            es = "No se pudieron leer las calidades; los botones siguen funcionando.",
            fr = "Qualités illisibles — les boutons ci-dessous fonctionnent toujours.",
            de = "Qualitäten nicht lesbar — die Schaltflächen funktionieren weiterhin.",
            ru = "Не удалось прочитать качества — кнопки ниже работают.",
            tr = "Kaliteler okunamadı — aşağıdaki düğmeler çalışıyor.",
            hi = "गुणवत्ता नहीं पढ़ी जा सकी — नीचे के बटन काम करते हैं।",
            zh = "无法读取画质，下方按钮仍可使用。",
        )
        val startFailed = pick(
            language,
            en = "Could not start the download.", ar = "مقدرش يبدأ التحميل.",
            es = "No se pudo iniciar la descarga.", fr = "Impossible de démarrer.",
            de = "Download konnte nicht gestartet werden.", ru = "Не удалось начать загрузку.",
            tr = "İndirme başlatılamadı.", hi = "डाउनलोड शुरू नहीं हो सका।",
            zh = "无法开始下载。",
        )

        private fun pick(
            language: String,
            en: String, ar: String, es: String, fr: String, de: String,
            ru: String, tr: String, hi: String, zh: String,
        ) = when (language) {
            "ar" -> ar; "es" -> es; "fr" -> fr; "de" -> de
            "ru" -> ru; "tr" -> tr; "hi" -> hi; "zh" -> zh
            else -> en
        }
    }
}
