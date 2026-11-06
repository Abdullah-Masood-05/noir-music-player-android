package com.example.noir_player

import java.io.ByteArrayOutputStream

/**
 * Builds the "udta" box that holds an M4A's tags (iTunes style, which the
 * media library and other players read): title, artist and cover.
 */
object M4aTags {
    private const val TYPE_UTF8 = 1
    private const val TYPE_JPEG = 13
    private const val TYPE_PNG = 14

    /** The complete udta box, or null when there's nothing to write. */
    fun udta(title: String?, artist: String?, cover: ByteArray?): ByteArray? {
        val items = mutableListOf<ByteArray>()
        title?.takeIf { it.isNotBlank() }?.let {
            items += box("©nam", data(TYPE_UTF8, it.toByteArray(Charsets.UTF_8)))
        }
        artist?.takeIf { it.isNotBlank() }?.let {
            items += box("©ART", data(TYPE_UTF8, it.toByteArray(Charsets.UTF_8)))
        }
        cover?.let { pictureType(it) }?.let { type ->
            items += box("covr", data(type, cover))
        }
        if (items.isEmpty()) return null

        val hdlr = box(
            "hdlr",
            int(0), // version and flags
            int(0), // pre-defined
            ascii("mdir"),
            ascii("appl"),
            int(0),
            int(0),
            byteArrayOf(0), // empty name
        )
        val meta = box("meta", int(0), hdlr, box("ilst", *items.toTypedArray()))
        return box("udta", meta)
    }

    /** JPEG or PNG from the first bytes; anything else isn't embedded. */
    private fun pictureType(b: ByteArray): Int? = when {
        b.size > 3 && b[0] == 0xFF.toByte() && b[1] == 0xD8.toByte() -> TYPE_JPEG
        b.size > 8 && b[0] == 0x89.toByte() && b[1] == 'P'.code.toByte() &&
            b[2] == 'N'.code.toByte() && b[3] == 'G'.code.toByte() -> TYPE_PNG
        else -> null
    }

    private fun data(type: Int, payload: ByteArray) = box("data", int(type), int(0), payload)

    private fun box(type: String, vararg parts: ByteArray): ByteArray {
        val size = 8 + parts.sumOf { it.size }
        val out = ByteArrayOutputStream(size)
        out.write(int(size))
        // Box names are bytes: "©nam" must stay one 0xA9 byte.
        out.write(type.toByteArray(Charsets.ISO_8859_1))
        parts.forEach { out.write(it) }
        return out.toByteArray()
    }

    private fun ascii(s: String) = s.toByteArray(Charsets.US_ASCII)

    private fun int(v: Int) = byteArrayOf(
        (v ushr 24).toByte(),
        (v ushr 16).toByte(),
        (v ushr 8).toByte(),
        v.toByte(),
    )
}
