package org.tessera

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

// Android companion — spec 10.5 REQUIRED
// Kotlin + Compose Material3, shared C++ core via FFI, Keystore
// Mirrors TesseraStudioiOS ContentView + ChatPanelView_iOS + NotesView_iOS
class MainActivity : ComponentActivity() {
    private external fun nativeInit(): String
    private external fun nativeChat(prompt: String): String
    companion object {
        init {
            try { System.loadLibrary("tessera-core") } catch (_: UnsatisfiedLinkError) {}
            try { System.loadLibrary("llama") } catch (_: UnsatisfiedLinkError) {}
        }
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val keystoreNote = try {
            val mk = MasterKey.Builder(this).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build()
            val prefs = EncryptedSharedPreferences.create(this, "tessera", mk,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM)
            prefs.getString("hello", null) ?: "no prior note"
        } catch (_: Exception) { "keystore unavailable" }
        setContent {
            MaterialTheme {
                val nav = rememberNavController()
                NavHost(nav, startDestination = "chat") {
                    composable("chat") { ChatScreen(onNativeChat = { p -> try { nativeChat(p) } catch (_: Exception) { "[native not loaded] echo: $p" } }) }
                    composable("notes") { NotesScreen(initial = keystoreNote) }
                    composable("reminders") { RemindersScreen() }
                }
            }
        }
    }
}

@Composable
fun ChatScreen(onNativeChat: (String) -> String) {
    var input by remember { mutableStateOf("") }
    var history by remember { mutableStateOf(listOf<String>()) }
    Column(Modifier.fillMaxSize().padding(16.dp)) {
        Text("Tessera — Chat", style = MaterialTheme.typography.titleLarge)
        LazyColumn(Modifier.weight(1f)) { items(history.size) { Text(history[it], Modifier.padding(4.dp)) } }
        Row {
            TextField(value = input, onValueChange = { input = it }, Modifier.weight(1f), placeholder = { Text("Message") })
            Button(onClick = { if(input.isNotBlank()){ val r = onNativeChat(input); history = history + "You: $input" + "\nTessy: $r"; input = "" } }, Modifier.padding(start = 8.dp)) { Text("Send") }
        }
    }
}

@Composable
fun NotesScreen(initial: String) {
    var text by remember { mutableStateOf(initial) }
    Column(Modifier.fillMaxSize().padding(16.dp)) {
        Text("Notes", style = MaterialTheme.typography.titleLarge)
        TextField(value = text, onValueChange = { text = it }, Modifier.fillMaxWidth().weight(1f))
    }
}

@Composable
fun RemindersScreen() {
    Column(Modifier.fillMaxSize().padding(16.dp)) {
        Text("Reminders", style = MaterialTheme.typography.titleLarge)
        Text("CalDAV via provider or local store — Compose list + detail")
    }
}
