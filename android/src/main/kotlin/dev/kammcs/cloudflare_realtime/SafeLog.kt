package dev.kammcs.cloudflare_realtime

/**
 * An exception's class name, for logcat: never its message, which can carry
 * a file path, a URI or what an app passed in (docs/design.md §4.9).
 * Logcat is readable over adb and often collected by crash reporters.
 */
internal fun Throwable.logName(): String = javaClass.simpleName.ifEmpty { javaClass.name }
