package yokai.core.sync

import java.io.File
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Test

/**
 * The merge scenarios in fixtures/sync/scenarios.json, which the iOS core tests run too (SyncScenarioTests), so both
 * versions merge the same way. With BOOKMANIA_WRITE_SYNC_SCENARIOS set, the expected results are written from this
 * implementation (review them before committing).
 */
class SyncScenarioTest {

    @Serializable
    data class LibraryExpected(val merged: LibraryState, val changes: LibraryChanges, val equal: List<String>)

    @Serializable
    data class LibraryCase(
        val snapshot: LibrarySnapshot = LibrarySnapshot(),
        val baseline: SyncBaseline = SyncBaseline(),
        val remotes: List<LibraryFile> = emptyList(),
        val expected: LibraryExpected? = null,
    )

    @Serializable
    data class ProgressExpected(val merged: ProgressState, val changes: ProgressChanges, val equal: List<String>)

    @Serializable
    data class ProgressCase(
        val snapshot: ProgressSnapshot = ProgressSnapshot(),
        val baseline: WorkBaseline = WorkBaseline(),
        val remotes: List<ProgressFile> = emptyList(),
        val expected: ProgressExpected? = null,
    )

    @Serializable
    data class Scenario(
        val name: String,
        val device: String,
        val now: Long,
        val library: LibraryCase? = null,
        val progress: ProgressCase? = null,
    )

    private val file = File("src/test/resources/fixtures/sync/scenarios.json")
    private val pretty = Json(SyncJson) { prettyPrint = true }

    private fun run(s: Scenario): Scenario {
        val lib = s.library?.let { c ->
            val local = SyncMerge.annotate(c.snapshot, c.baseline, s.now, s.device)
            val merged = SyncMerge.merge(local, c.remotes.map { it.state }, s.now, s.device)
            val (changes, equal) = SyncMerge.changes(merged, c.snapshot)
            c.copy(expected = LibraryExpected(merged, changes, equal.sorted()))
        }
        val progress = s.progress?.let { c ->
            val local = SyncMerge.annotate(c.snapshot, c.baseline, s.now, s.device)
            val merged = SyncMerge.mergeProgress(local, c.remotes.map { it.state }, s.now, s.device)
            val (changes, equal) = SyncMerge.changes(merged, c.snapshot)
            c.copy(expected = ProgressExpected(merged, changes, equal.sorted()))
        }
        return s.copy(library = lib, progress = progress)
    }

    @Test
    fun `the shared merge scenarios`() {
        val serializer = ListSerializer(Scenario.serializer())
        val scenarios = SyncJson.decodeFromString(serializer, file.readText())
        val results = scenarios.map(::run)
        if (System.getenv("BOOKMANIA_WRITE_SYNC_SCENARIOS") != null) {
            file.writeText(pretty.encodeToString(serializer, results) + "\n")
            return
        }
        for ((given, got) in scenarios.zip(results)) {
            given.library?.let {
                assertNotNull(it.expected, given.name)
                assertEquals(it.expected, got.library!!.expected, given.name)
            }
            given.progress?.let {
                assertNotNull(it.expected, given.name)
                assertEquals(it.expected, got.progress!!.expected, given.name)
            }
        }
    }
}
