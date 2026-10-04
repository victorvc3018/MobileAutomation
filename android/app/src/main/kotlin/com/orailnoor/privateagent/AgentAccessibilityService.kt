package com.orailnoor.privateagent

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.Intent
import android.graphics.Bitmap
import android.hardware.HardwareBuffer
import android.graphics.Path
import android.graphics.Rect
import android.os.Build
import android.os.Bundle
import android.util.Base64
import android.util.Log
import android.view.Display
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import androidx.annotation.RequiresApi
import java.io.ByteArrayOutputStream

class AgentAccessibilityService : AccessibilityService() {

    private val ownPackageName = "com.orailnoor.privateagent"

    companion object {
        var instance: AgentAccessibilityService? = null
            private set
            
        var eventListener: ((Map<String, Any>) -> Unit)? = null

        fun isRunning(): Boolean = instance != null
    }

    @Volatile
    var lastEventTimestamp: Long = android.os.SystemClock.uptimeMillis()

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        lastEventTimestamp = android.os.SystemClock.uptimeMillis()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return

        // Filter out events from our own app so we don't record the Stop Overlay button clicks or internal UI
        if (event.packageName?.toString() == "com.orailnoor.privateagent") return

        // Record real-time OS event timestamp for adaptive settling detection
        lastEventTimestamp = android.os.SystemClock.uptimeMillis()

        val listener = eventListener ?: return
        
        when (event.eventType) {
            AccessibilityEvent.TYPE_VIEW_CLICKED -> {
                val node = event.source
                var text = node?.text?.toString() ?: node?.contentDescription?.toString() ?: ""
                if (text.isEmpty() && event.text.isNotEmpty()) {
                    text = event.text.joinToString(" ")
                }
                
                val rect = Rect()
                node?.getBoundsInScreen(rect)
                val cx = rect.centerX()
                val cy = rect.centerY()
                
                // Only record if we have valid text or valid coordinates
                if (text.isNotEmpty() || (cx != 0 || cy != 0)) {
                    val map = mapOf(
                        "type" to "click",
                        "text" to text,
                        "x" to cx,
                        "y" to cy
                    )
                    listener(map)
                }
                node?.recycle()
            }
            AccessibilityEvent.TYPE_VIEW_SCROLLED -> {
                val map = mapOf("type" to "scroll")
                listener(map)
            }
        }
    }

    /**
     * Adaptively waits until UI events have quieted down (screen settled)
     * or maximum timeout is reached.
     */
    fun waitForScreenSettle(maxWaitMs: Long, quietPeriodMs: Long): Boolean {
        val initialGraceMs = 80L
        val startTime = android.os.SystemClock.uptimeMillis()
        val deadline = startTime + maxWaitMs

        try {
            Thread.sleep(initialGraceMs)
        } catch (_: InterruptedException) {
            return false
        }

        while (android.os.SystemClock.uptimeMillis() < deadline) {
            val now = android.os.SystemClock.uptimeMillis()
            val quietDuration = now - lastEventTimestamp
            if (quietDuration >= quietPeriodMs) {
                return true
            }
            try {
                Thread.sleep(25L)
            } catch (_: InterruptedException) {
                return false
            }
        }
        return false
    }

    override fun onInterrupt() {}

    override fun onDestroy() {
        super.onDestroy()
        instance = null
    }

    // ─── Screen Reading ──────────────────────────────────────────

    /** Dump the current screen as a flat list of UI elements */
    fun dumpScreen(): List<Map<String, Any?>> {
        val nodes = mutableListOf<Map<String, Any?>>()
        val allWindows = windows
        if (allWindows == null || allWindows.isEmpty()) {
            val root = rootInActiveWindow ?: return emptyList()
            if (root.packageName?.toString() != ownPackageName) {
                traverseNode(root, nodes, 0)
            }
            root.recycle()
            return nodes
        }
        
        for (window in allWindows) {
            val root = window.root ?: continue
            if (root.packageName?.toString() == ownPackageName) {
                root.recycle()
                continue
            }
            traverseNode(root, nodes, 0)
            root.recycle()
        }
        return nodes
    }

    private fun traverseNode(
        node: AccessibilityNodeInfo,
        nodes: MutableList<Map<String, Any?>>,
        depth: Int
    ) {
        val rect = Rect()
        node.getBoundsInScreen(rect)

        val text = node.text?.toString() ?: ""
        val contentDesc = node.contentDescription?.toString() ?: ""
        val className = node.className?.toString() ?: ""
        val viewId = node.viewIdResourceName ?: ""

        // Filter out completely hidden or zero-size nodes (like scrolled-out WebView elements)
        val isZeroSize = rect.width() <= 0 || rect.height() <= 0
        if (!node.isVisibleToUser || isZeroSize) {
            for (i in 0 until node.childCount) {
                val child = node.getChild(i) ?: continue
                traverseNode(child, nodes, depth + 1)
                child.recycle()
            }
            return
        }

        // Only include nodes that have text/description or are interactive
        if (text.isNotEmpty() || contentDesc.isNotEmpty() ||
            node.isClickable || node.isEditable || node.isScrollable
        ) {
            nodes.add(
                mapOf(
                    "index" to nodes.size,
                    "text" to text,
                    "contentDescription" to contentDesc,
                    "className" to className.substringAfterLast('.'),
                    "viewId" to viewId,
                    "isClickable" to node.isClickable,
                    "isEditable" to node.isEditable,
                    "isScrollable" to node.isScrollable,
                    "isCheckable" to node.isCheckable,
                    "isChecked" to node.isChecked,
                    "isFocused" to node.isFocused,
                    "bounds" to mapOf(
                        "left" to rect.left,
                        "top" to rect.top,
                        "right" to rect.right,
                        "bottom" to rect.bottom
                    ),
                    "depth" to depth
                )
            )
        }

        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            traverseNode(child, nodes, depth + 1)
            child.recycle()
        }
    }

    /** Capture screenshot as Base64 string with metadata and aspect-ratio downscaling (Item #1 Optimization) */
    @RequiresApi(Build.VERSION_CODES.R)
    fun takeScreenshot(
        targetWidth: Int = 720,
        quality: Int = 75,
        callback: (Map<String, Any>?) -> Unit
    ) {
        takeScreenshot(
            Display.DEFAULT_DISPLAY,
            mainExecutor,
            object : TakeScreenshotCallback {
                override fun onSuccess(screenshotResult: ScreenshotResult) {
                    val hardwareBuffer = screenshotResult.hardwareBuffer
                    val bitmap = Bitmap.wrapHardwareBuffer(hardwareBuffer, screenshotResult.colorSpace)
                        ?.copy(Bitmap.Config.ARGB_8888, false)

                    hardwareBuffer.close()

                    if (bitmap != null) {
                        try {
                            val nativeWidth = bitmap.width
                            val nativeHeight = bitmap.height

                            // Downscale while preserving aspect ratio
                            val scaleFactor: Float = if (nativeWidth <= nativeHeight) {
                                if (nativeWidth > targetWidth) targetWidth.toFloat() / nativeWidth.toFloat() else 1.0f
                            } else {
                                val maxLandscapeWidth = (targetWidth * 16) / 9
                                if (nativeWidth > maxLandscapeWidth) maxLandscapeWidth.toFloat() / nativeWidth.toFloat() else 1.0f
                            }

                            val scaledWidth = (nativeWidth * scaleFactor).toInt().coerceAtLeast(1)
                            val scaledHeight = (nativeHeight * scaleFactor).toInt().coerceAtLeast(1)

                            val scaledBitmap = if (scaleFactor < 0.99f) {
                                Bitmap.createScaledBitmap(bitmap, scaledWidth, scaledHeight, true).also {
                                    if (it != bitmap) bitmap.recycle()
                                }
                            } else {
                                bitmap
                            }

                            val byteArrayOutputStream = ByteArrayOutputStream()
                            scaledBitmap.compress(Bitmap.CompressFormat.JPEG, quality, byteArrayOutputStream)
                            scaledBitmap.recycle()

                            val byteArray = byteArrayOutputStream.toByteArray()
                            val base64String = Base64.encodeToString(byteArray, Base64.NO_WRAP)

                            val resultMap = mapOf<String, Any>(
                                "base64" to base64String,
                                "width" to scaledWidth,
                                "height" to scaledHeight,
                                "nativeWidth" to nativeWidth,
                                "nativeHeight" to nativeHeight,
                                "scale" to scaleFactor.toDouble()
                            )
                            callback(resultMap)
                        } catch (e: Exception) {
                            Log.e("AgentAccessibility", "Screenshot downscaling error", e)
                            callback(null)
                        }
                    } else {
                        callback(null)
                    }
                }

                override fun onFailure(errorCode: Int) {
                    Log.e("AgentAccessibility", "takeScreenshot failed: $errorCode")
                    callback(null)
                }
            }
        )
    }

    @RequiresApi(Build.VERSION_CODES.R)
    fun takeScreenshot(callback: (String?) -> Unit) {
        takeScreenshot(720, 75) { map ->
            callback(map?.get("base64") as? String)
        }
    }

    // ─── Actions ─────────────────────────────────────────────────

    /** Find and click a node by its text content */
    fun clickByText(targetText: String): Boolean {
        for (window in windows) {
            val root = window.root ?: continue
            if (root.packageName?.toString() == ownPackageName) {
                root.recycle()
                continue
            }
            // Prefer an actual suggestion/button over an editable search field
            // that contains the same query. Editables remain the final fallback
            // so the agent can still focus a search box by its label.
            val result = findAndClickNode(root, targetText, true, true)
                || findAndClickNode(root, targetText, false, true)
                || findAndClickNode(root, targetText, true, false)
                || findAndClickNode(root, targetText, false, false)
            root.recycle()
            if (result) return true
        }
        return false
    }

    private fun findAndClickNode(
        node: AccessibilityNodeInfo,
        targetText: String,
        exactOnly: Boolean,
        skipEditable: Boolean
    ): Boolean {
        val text = node.text?.toString() ?: ""
        val desc = node.contentDescription?.toString() ?: ""

        val exactMatch = text.equals(targetText, ignoreCase = true)
            || desc.equals(targetText, ignoreCase = true)
        val containsMatch = text.contains(targetText, ignoreCase = true)
            || desc.contains(targetText, ignoreCase = true)
        val matches = if (exactOnly) exactMatch else containsMatch

        if (matches && (!skipEditable || !node.isEditable) && clickNodeOrParent(node)) {
            return true
        }

        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            if (findAndClickNode(child, targetText, exactOnly, skipEditable)) {
                child.recycle()
                return true
            }
            child.recycle()
        }
        return false
    }

    private fun clickNodeOrParent(node: AccessibilityNodeInfo): Boolean {
        var clickTarget: AccessibilityNodeInfo? = node
        while (clickTarget != null && !clickTarget.isClickable) {
            clickTarget = clickTarget.parent
        }
        if (clickTarget?.performAction(AccessibilityNodeInfo.ACTION_CLICK) == true) {
            return true
        }

        val rect = Rect()
        node.getBoundsInScreen(rect)
        return !rect.isEmpty && clickAtCoordinates(
            rect.centerX().toFloat(),
            rect.centerY().toFloat()
        )
    }

    /** Click at specific coordinates using gesture */
    fun clickAtCoordinates(x: Float, y: Float): Boolean {
        val path = Path()
        path.moveTo(x, y)
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, 100))
            .build()
        return dispatchGesture(gesture, null, null)
    }

    fun typeText(text: String, fieldHint: String? = null): Boolean {
        for (window in windows) {
            val root = window.root ?: continue
            if (root.packageName?.toString() == ownPackageName) {
                root.recycle()
                continue
            }

            var editNode = findEditableNode(root, fieldHint)
            if (editNode == null && !fieldHint.isNullOrEmpty()) {
                editNode = findEditableNode(root, null)
            }

            if (editNode != null) {
                editNode.performAction(AccessibilityNodeInfo.ACTION_FOCUS)
                val args = Bundle()
                args.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
                val success = editNode.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
                root.recycle()
                return success
            }
            root.recycle()
        }
        return false
    }

    /** Submit the focused field through the IME, with keyboard-aware fallbacks. */
    fun pressEnter(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            for (window in windows) {
                val root = window.root ?: continue
                if (root.packageName?.toString() == ownPackageName) {
                    root.recycle()
                    continue
                }
                val focused = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
                val submitted = focused?.performAction(
                    AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id
                ) == true
                focused?.recycle()
                root.recycle()
                if (submitted) return true
            }
        }

        for (window in windows) {
            val root = window.root ?: continue
            val actionNode = findKeyboardActionNode(root)
            val submitted = actionNode != null && clickNodeOrParent(actionNode)
            actionNode?.recycle()
            root.recycle()
            if (submitted) return true
        }

        // Tap inside the actual IME window, avoiding the navigation bar.
        for (window in windows) {
            if (window.type != AccessibilityWindowInfo.TYPE_INPUT_METHOD) continue
            val bounds = Rect()
            window.getBoundsInScreen(bounds)
            if (!bounds.isEmpty) {
                val x = bounds.right - (bounds.width() * 0.10f)
                val y = bounds.bottom - (bounds.height() * 0.14f)
                return clickAtCoordinates(x, y)
            }
        }
        return false
    }

    private fun findKeyboardActionNode(node: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        val label = (node.text?.toString().orEmpty().ifEmpty {
            node.contentDescription?.toString().orEmpty()
        }).trim().lowercase()
        val actionLabels = setOf("search", "enter", "go", "done", "send", "next")
        if (node.isClickable && (label in actionLabels || label.endsWith(" search"))) {
            return AccessibilityNodeInfo.obtain(node)
        }

        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            val found = findKeyboardActionNode(child)
            child.recycle()
            if (found != null) return found
        }
        return null
    }

    private fun findEditableNode(
        node: AccessibilityNodeInfo,
        hint: String?
    ): AccessibilityNodeInfo? {
        if (node.isEditable) {
            if (hint == null) return node
            val text = node.text?.toString() ?: ""
            val desc = node.contentDescription?.toString() ?: ""
            val hintText = node.hintText?.toString() ?: ""
            if (text.contains(hint, ignoreCase = true) ||
                desc.contains(hint, ignoreCase = true) ||
                hintText.contains(hint, ignoreCase = true)
            ) {
                return node
            }
            // If no hint match but this is the first editable, return it
            if (hint.isNullOrEmpty()) return node
        }

        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            val found = findEditableNode(child, hint)
            if (found != null) return found
            child.recycle()
        }
        return null
    }

    /** Scroll forward on the first scrollable element, or a specific one by text */
    fun scroll(direction: String, targetText: String? = null): Boolean {
        for (window in windows) {
            val root = window.root ?: continue
            if (root.packageName?.toString() == ownPackageName) {
                root.recycle()
                continue
            }
            val scrollNode = findScrollableNode(root, targetText)
            if (scrollNode != null) {
                val action = when (direction.lowercase()) {
                    "down", "forward" -> AccessibilityNodeInfo.ACTION_SCROLL_FORWARD
                    "up", "backward" -> AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD
                    else -> AccessibilityNodeInfo.ACTION_SCROLL_FORWARD
                }
                val success = scrollNode.performAction(action)
                root.recycle()
                return success
            }
            root.recycle()
        }
        return false
    }

    private fun findScrollableNode(
        node: AccessibilityNodeInfo,
        targetText: String?
    ): AccessibilityNodeInfo? {
        if (node.isScrollable) {
            if (targetText == null) return node
            val text = node.text?.toString() ?: ""
            val desc = node.contentDescription?.toString() ?: ""
            if (text.contains(targetText, ignoreCase = true) ||
                desc.contains(targetText, ignoreCase = true)
            ) {
                return node
            }
        }
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            val found = findScrollableNode(child, targetText)
            if (found != null) return found
            child.recycle()
        }
        return null
    }

    /** Press the global back button */
    fun pressBack(): Boolean {
        return performGlobalAction(GLOBAL_ACTION_BACK)
    }

    /** Press the global home button */
    fun pressHome(): Boolean {
        return performGlobalAction(GLOBAL_ACTION_HOME)
    }

    /** Open recent apps */
    fun openRecents(): Boolean {
        return performGlobalAction(GLOBAL_ACTION_RECENTS)
    }

    /** Open notifications */
    fun openNotifications(): Boolean {
        return performGlobalAction(GLOBAL_ACTION_NOTIFICATIONS)
    }

    /** Swipe gesture */
    fun swipe(startX: Float, startY: Float, endX: Float, endY: Float, durationMs: Long = 300): Boolean {
        val path = Path()
        path.moveTo(startX, startY)
        path.lineTo(endX, endY)
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, durationMs))
            .build()
        return dispatchGesture(gesture, null, null)
    }

    /** Long press at coordinates */
    fun longPressAt(x: Float, y: Float): Boolean {
        val path = Path()
        path.moveTo(x, y)
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, 1000))
            .build()
        return dispatchGesture(gesture, null, null)
    }

    /** Get the currently focused app's package name */
    fun getCurrentPackage(): String? {
        var ownApplicationSeen = false
        var fallbackApplication: String? = null

        for (window in windows) {
            val root = window.root ?: continue
            val pkg = root.packageName?.toString()
            root.recycle()

            if (pkg == null || window.type != AccessibilityWindowInfo.TYPE_APPLICATION) {
                continue
            }

            // An active PrivateAgent application window is the main Flutter app.
            // Return it so TaskExecutor can press Home before taking its first dump.
            // The floating overlay is a system overlay, not an application window.
            if (window.isActive || window.isFocused) {
                return pkg
            }

            if (pkg == ownPackageName) {
                ownApplicationSeen = true
            } else if (fallbackApplication == null) {
                fallbackApplication = pkg
            }
        }

        return fallbackApplication ?: if (ownApplicationSeen) ownPackageName else null
    }
}
