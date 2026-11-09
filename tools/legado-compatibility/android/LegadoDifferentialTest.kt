package io.legado.app.compatibility

import android.os.Build
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.legado.app.data.entities.Book
import io.legado.app.model.analyzeRule.AnalyzeRule
import java.io.File
import java.security.MessageDigest
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Repository-authored offline fixtures, evaluated by the unmodified pinned Android engine. */
@RunWith(AndroidJUnit4::class)
class LegadoDifferentialTest {
    @Test
    fun recordOfflineRules() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val bytes = instrumentation.context.assets.open("legado-compatibility-corpus.json").use { it.readBytes() }
        val corpus = JSONObject(bytes.toString(Charsets.UTF_8))
        assertEquals(1, corpus.getInt("schemaVersion"))
        val cases = corpus.getJSONArray("cases")
        val results = JSONArray()
        for (index in 0 until cases.length()) {
            val fixture = cases.getJSONObject(index)
            val book = Book()
            val initial = fixture.getJSONObject("variables")
            initial.keys().forEach { key -> book.putVariable(key, initial.getString(key)) }
            // A fresh analyzer and book for every case. No source/account/database persistence.
            val analyzer = AnalyzeRule(ruleData = book).setContent(
                fixture.getString("input"), fixture.getString("baseURL")
            )
            val observation = JSONObject().put("id", fixture.getString("id"))
            val values = JSONArray()
            val errors = JSONArray()
            try {
                val rule = fixture.getString("rule")
                when (fixture.getString("mode")) {
                    "list" -> analyzer.getStringList(rule)?.forEach { values.put(it) }
                    "string" -> values.put(analyzer.getString(rule))
                    else -> error("Unknown corpus mode")
                }
                observation.put("outcome", "success")
            } catch (error: Exception) {
                observation.put("outcome", "error")
                errors.put(JSONObject().put("code", error.javaClass.name)
                    .put("message", (error.message ?: "").take(1024)))
            }
            val variables = JSONObject()
            val inspected = fixture.getJSONArray("inspectVariables")
            for (variableIndex in 0 until inspected.length()) {
                val key = inspected.getString(variableIndex)
                variables.put(key, analyzer.get(key))
            }
            results.put(observation.put("values", values).put("variables", variables).put("errors", errors))
        }
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
        val report = JSONObject().put("schemaVersion", 1)
            .put("engine", "android-legado-reference")
            .put("referenceCommit", corpus.getString("referenceCommit"))
            .put("corpusSHA256", digest)
            .put("environment", JSONObject().put("sdk", Build.VERSION.SDK_INT)
                .put("model", Build.MODEL).put("fingerprint", Build.FINGERPRINT))
            .put("results", results)
        val destination = File(instrumentation.targetContext.filesDir, "legado-compatibility-android.json")
        val temporary = File(destination.parentFile, destination.name + ".tmp")
        temporary.writeText(report.toString(2) + "\n", Charsets.UTF_8)
        assertTrue("Save complete report", temporary.renameTo(destination))
        assertEquals(cases.length(), results.length())
        // An independent sanity anchor detects a runner that only records failures or empty output.
        for (index in 0 until cases.length()) {
            val fixture = cases.getJSONObject(index)
            if (fixture.has("sanityValues")) {
                assertEquals("success", results.getJSONObject(index).getString("outcome"))
                assertEquals(fixture.getJSONArray("sanityValues").toString(),
                    results.getJSONObject(index).getJSONArray("values").toString())
            }
        }
    }
}
