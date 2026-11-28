package yokai.sync

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import co.touchlab.kermit.Logger
import eu.kanade.tachiyomi.util.system.workManager
import java.util.concurrent.TimeUnit
import uy.kohesive.injekt.Injekt
import uy.kohesive.injekt.api.get
import yokai.core.sync.SyncException
import yokai.core.sync.SyncIds

/**
 * The WebDAV sync's background jobs: sending a work's progress after reading, syncing the library (then the book
 * files), and the book files on their own (only on networks that are not metered, unless the user allows any).
 */
class SyncWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        val manager = Injekt.get<SyncManager>()
        if (!manager.isConfigured()) return Result.success()
        return try {
            when (inputData.getString(KEY_KIND)) {
                KIND_WORK -> inputData.getString(KEY_WORK)?.let { manager.syncWork(it, push = true) }
                KIND_FILES -> manager.syncFiles()
                else -> {
                    manager.syncLibrary()
                    files(applicationContext)
                }
            }
            Result.success()
        } catch (e: SyncException) {
            Logger.w(e) { "WebDAV sync failed" }
            when (e.kind) {
                SyncException.Kind.Network, SyncException.Kind.Http -> Result.retry()
                else -> Result.failure()
            }
        }
    }

    companion object {
        private const val KEY_KIND = "kind"
        private const val KEY_WORK = "work"
        private const val KIND_LIBRARY = "library"
        private const val KIND_WORK = "work"
        private const val KIND_FILES = "files"
        private const val NAME_LIBRARY = "bookmania-sync-library"
        private const val NAME_FILES = "bookmania-sync-files"

        private val connected = Constraints(requiredNetworkType = NetworkType.CONNECTED)

        fun library(context: Context, delaySeconds: Long = 0) {
            val request = OneTimeWorkRequestBuilder<SyncWorker>()
                .setConstraints(connected)
                .setInitialDelay(delaySeconds, TimeUnit.SECONDS)
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
                .setInputData(workDataOf(KEY_KIND to KIND_LIBRARY))
                .build()
            val policy = if (delaySeconds > 0) ExistingWorkPolicy.REPLACE else ExistingWorkPolicy.KEEP
            context.workManager.enqueueUniqueWork(NAME_LIBRARY, policy, request)
        }

        fun push(context: Context, work: String) {
            val request = OneTimeWorkRequestBuilder<SyncWorker>()
                .setConstraints(connected)
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
                .setInputData(workDataOf(KEY_KIND to KIND_WORK, KEY_WORK to work))
                .build()
            val name = "bookmania-sync-work-" + SyncIds.progressFileName(work).removeSuffix(".json")
            context.workManager.enqueueUniqueWork(name, ExistingWorkPolicy.REPLACE, request)
        }

        fun files(context: Context) {
            val prefs = Injekt.get<SyncPreferences>()
            if (!prefs.syncFiles().get()) return
            val network = if (prefs.filesUnmeteredOnly().get()) NetworkType.UNMETERED else NetworkType.CONNECTED
            val request = OneTimeWorkRequestBuilder<SyncWorker>()
                .setConstraints(Constraints(requiredNetworkType = network))
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 60, TimeUnit.SECONDS)
                .setInputData(workDataOf(KEY_KIND to KIND_FILES))
                .build()
            context.workManager.enqueueUniqueWork(NAME_FILES, ExistingWorkPolicy.KEEP, request)
        }
    }
}
