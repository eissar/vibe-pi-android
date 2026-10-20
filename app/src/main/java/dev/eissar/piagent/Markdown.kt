package dev.eissar.piagent

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.mikepenz.markdown.compose.components.markdownComponents
import com.mikepenz.markdown.compose.elements.MarkdownHighlightedCodeBlock
import com.mikepenz.markdown.compose.elements.MarkdownHighlightedCodeFence
import com.mikepenz.markdown.m3.Markdown
import com.mikepenz.markdown.m3.markdownTypography
import com.mikepenz.markdown.model.markdownPadding
import com.mikepenz.markdown.utils.buildMarkdownAnnotatedString
import dev.snipme.highlights.Highlights
import dev.snipme.highlights.model.SyntaxThemes
import org.intellij.markdown.ast.ASTNode
import org.intellij.markdown.flavours.gfm.GFMElementTypes
import org.intellij.markdown.flavours.gfm.GFMTokenTypes

// Compact type scale for chat (library defaults use display/headline styles).
private val Body = TextStyle(fontSize = 14.sp, lineHeight = 20.sp)
private val CodeStyle = TextStyle(fontSize = 12.sp, lineHeight = 17.sp, fontFamily = FontFamily.Monospace)
private fun heading(size: Int) = TextStyle(fontSize = size.sp, lineHeight = (size + 6).sp, fontWeight = FontWeight.SemiBold)

@Composable
fun ChatMarkdown(text: String, modifier: Modifier = Modifier) {
    val highlights = remember { Highlights.Builder().theme(SyntaxThemes.atom(darkMode = true)) }
    Markdown(
        text,
        modifier = modifier.fillMaxWidth(),
        typography = markdownTypography(
            h1 = heading(19), h2 = heading(17), h3 = heading(16), h4 = heading(15), h5 = heading(14), h6 = heading(14),
            text = Body, paragraph = Body, ordered = Body, bullet = Body, list = Body,
            code = CodeStyle, inlineCode = Body.copy(fontFamily = FontFamily.Monospace, fontSize = 13.sp),
            quote = Body.copy(color = MaterialTheme.colorScheme.onSurfaceVariant),
            link = Body.copy(color = MaterialTheme.colorScheme.primary),
        ),
        padding = markdownPadding(block = 3.dp, list = 4.dp, listItemBottom = 2.dp),
        components = markdownComponents(
            codeFence = { MarkdownHighlightedCodeFence(it.content, it.node, highlights) },
            codeBlock = { MarkdownHighlightedCodeBlock(it.content, it.node, highlights) },
            table = { Table(it.content, it.node) },
        ),
    )
}

/**
 * GFM table sized to its content: each column is as wide as its widest cell (capped,
 * then wrapped), rows align, and the whole table scrolls sideways when too wide.
 */
@Composable
private fun Table(content: String, node: ASTNode) {
    val rows = remember(node) {
        node.children.filter { it.type == GFMElementTypes.HEADER || it.type == GFMElementTypes.ROW }
            .map { row -> row.children.filter { it.type == GFMTokenTypes.CELL } }
    }
    if (rows.isEmpty()) return
    val cols = rows.maxOf { it.size }
    val line = MaterialTheme.colorScheme.outlineVariant
    val headerBg = MaterialTheme.colorScheme.surfaceContainerHigh
    Layout(
        modifier = Modifier.padding(vertical = 6.dp).horizontalScroll(rememberScrollState())
            .border(1.dp, line, RoundedCornerShape(6.dp)),
        content = {
            rows.forEachIndexed { r, cells ->
                for (c in 0 until cols) {
                    val cell = cells.getOrNull(c)
                    val style = if (r == 0) Body.copy(fontWeight = FontWeight.SemiBold) else Body
                    Text(
                        cell?.let { content.buildMarkdownAnnotatedString(it, style) } ?: androidx.compose.ui.text.AnnotatedString(""),
                        Modifier.widthIn(max = 260.dp)
                            .background(if (r == 0) headerBg else Color.Transparent)
                            .padding(horizontal = 8.dp, vertical = 5.dp),
                        style = style,
                    )
                }
            }
        },
    ) { measurables, _ ->
        // Column width = widest cell's natural width (cells cap themselves via widthIn);
        // row height = tallest cell at that width. Every cell then fills its slot.
        val widths = IntArray(cols)
        measurables.forEachIndexed { i, m -> widths[i % cols] = maxOf(widths[i % cols], m.maxIntrinsicWidth(Constraints.Infinity)) }
        val heights = measurables.chunked(cols).map { row -> row.withIndex().maxOf { (c, m) -> m.minIntrinsicHeight(widths[c]) } }
        val filled = measurables.mapIndexed { i, m ->
            val w = widths[i % cols]; val h = heights[i / cols]
            m.measure(Constraints.fixed(w, h))
        }
        layout(widths.sum(), heights.sum()) {
            var y = 0
            filled.chunked(cols).forEachIndexed { r, row ->
                var x = 0
                row.forEachIndexed { c, p -> p.place(x, y); x += widths[c] }
                y += heights[r]
            }
        }
    }
}
