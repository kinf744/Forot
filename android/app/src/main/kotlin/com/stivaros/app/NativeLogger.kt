package com.stivaros.app

import android.util.Log
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

object NativeLogger {
    private const val TAG = "StivarosLog"
    private var logFile: File? = null
    private val dateFormat = SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", Locale.US)

    fun init(file: File) {
        logFile = file
        if (file.exists()) file.delete()
        file.createNewFile()
        i("NativeLogger", "Log file initialized: ${file.absolutePath}")
    }

    fun i(tag: String, msg: String) { log("INFO", tag, msg) }
    fun w(tag: String, msg: String) { log("WARN", tag, msg) }
    fun e(tag: String, msg: String) { log("ERROR", tag, msg) }

    private fun log(level: String, tag: String, msg: String) {
        val time = dateFormat.format(Date())
        val line = "[$time] [$level] [$tag] $msg"
        Log.d(TAG, line)
        try {
            logFile?.appendText("$line\n")
        } catch (_: Exception) {}
    }
}
