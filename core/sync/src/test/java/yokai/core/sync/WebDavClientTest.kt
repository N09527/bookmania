package yokai.core.sync

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class WebDavClientTest {

    @Test
    fun `only https addresses`() {
        val dav = InMemoryWebDav()
        for (bad in listOf("http://example.com/dav/", "ftp://example.com/", "example.com/dav", "https:///dav")) {
            val e = assertThrows(SyncException::class.java) { WebDavClient(bad, "u", "p", dav) }
            assertEquals(SyncException.Kind.Config, e.kind)
        }
        assertEquals("https://example.com/dav/", WebDavClient("https://example.com/dav", "u", "p", dav).base)
    }

    @Test
    fun `path segments are percent-encoded`() {
        assertEquals("%E7%9B%B4%E6%8E%92%20EPUB", WebDavClient.encodeSegment("直排 EPUB"))
        assertEquals("a-b_c.d~e", WebDavClient.encodeSegment("a-b_c.d~e"))
        assertEquals("%2F%3F%23%25", WebDavClient.encodeSegment("/?#%"))
        assertEquals("直排 EPUB/😀", WebDavClient.decodePath("%E7%9B%B4%E6%8E%92%20EPUB/%F0%9F%98%80"))
        assertEquals("直排 EPUB", WebDavClient.decodePath("直排%20EPUB"))
        val client = WebDavClient("https://example.com/dav/", "u", "p", InMemoryWebDav())
        assertEquals("https://example.com/dav/Bookmania/%E4%BD%9C%E5%93%81/", client.url(listOf("Bookmania", "作品"), collection = true))
    }

    private val listing = """<?xml version="1.0"?>
<D:multistatus xmlns:D="DAV:" xmlns:lp1="http://apache.org/dav/props/">
<D:response><D:href>/dav/Bookmania/sync-v1/devices/</D:href>
 <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
<D:response><D:href>https://example.com/dav/Bookmania/sync-v1/devices/6f1c2b9e-3d4a-4e5f-8a7b-1c2d3e4f5a6b/</D:href>
 <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype><D:getetag>"a1"</D:getetag></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
 <D:propstat><D:prop><D:getcontentlength/></D:prop><D:status>HTTP/1.1 404 Not Found</D:status></D:propstat></D:response>
<D:response><D:href>/dav/Bookmania/sync-v1/devices/%E4%BD%9C%E5%93%81.json</D:href>
 <D:propstat><D:prop><D:resourcetype/><D:getcontentlength>42</D:getcontentlength><lp1:executable>F</lp1:executable></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
</D:multistatus>"""

    @Test
    fun `a listing with another prefix, full URLs and encoded names`() {
        val entries = WebDavClient.parseMultistatus(listing, "https://example.com/dav/Bookmania/sync-v1/devices/")
        assertEquals(
            listOf(
                DavEntry("6f1c2b9e-3d4a-4e5f-8a7b-1c2d3e4f5a6b", true, "\"a1\"", null),
                DavEntry("作品.json", false, null, 42),
            ),
            entries,
        )
    }

    @Test
    fun `a listing in the default namespace`() {
        val xml = """<multistatus xmlns="DAV:"><response><href>/dav/x/</href><propstat><prop><resourcetype><collection/></resourcetype></prop><status>HTTP/1.1 200 OK</status></propstat></response>
            <response><href>/dav/x/y</href><propstat><prop><resourcetype></resourcetype><getcontentlength>7</getcontentlength></prop><status>HTTP/1.1 200 OK</status></propstat></response></multistatus>"""
        assertEquals(listOf(DavEntry("y", false, null, 7)), WebDavClient.parseMultistatus(xml, "https://h/dav/x/"))
    }

    @Test
    fun `document type declarations are skipped, not processed`() {
        val xml = """<?xml version="1.0"?>
<!DOCTYPE d:multistatus [ <!ENTITY xxe SYSTEM "file:///etc/passwd"> <!ENTITY big "aaaaaaaaaa"> ]>
<d:multistatus xmlns:d="DAV:"><d:response><d:href>/dav/&xxe;&big;&amp;x</d:href>
<d:propstat><d:prop><d:resourcetype/></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>"""
        val entries = WebDavClient.parseMultistatus(xml, "https://h/dav/")
        // The undefined entities stay as text; only &amp; is decoded.
        assertEquals("&xxe;&big;&x", entries.single().name)
    }

    @Test
    fun `responses that are not a listing`() {
        assertThrows(SyncException::class.java) { WebDavClient.parseMultistatus("<html><body>login</body></html>", "https://h/") }
        assertThrows(SyncException::class.java) { WebDavClient.parseMultistatus("<d:multistatus xmlns:d=\"DAV:\"><d:response>", "https://h/") }
    }

    @Test
    fun `requests against the in-memory server`() {
        val server = InMemoryWebDav(prefix = "", fullUrlHrefs = true, encodeHrefs = false)
        val dav = WebDavClient(server.base, "reader", "secret", server)
        dav.ensureCollections(listOf("Bookmania", "作品"))
        dav.ensureCollections(listOf("Bookmania", "作品")) // existing collections are fine
        dav.putJson(listOf("Bookmania", "作品", "a b.json"), "{}")
        assertEquals("{}", dav.get(listOf("Bookmania", "作品", "a b.json"))!!.decodeToString())
        assertNull(dav.get(listOf("Bookmania", "missing.json")))
        assertEquals(listOf(DavEntry("作品", true, null, null)), dav.list(listOf("Bookmania")))
        assertEquals(listOf(DavEntry("a b.json", false, null, 2)), dav.list(listOf("Bookmania", "作品")))
        assertTrue(dav.list(listOf("nothing")).isEmpty())
        val e = assertThrows(SyncException::class.java) { dav.putJson(listOf("no", "parent.json"), "{}") }
        assertEquals(409, e.status)

        val wrong = WebDavClient(server.base, "reader", "wrong", server)
        assertEquals(SyncException.Kind.Auth, assertThrows(SyncException::class.java) { wrong.get(listOf("x")) }.kind)
    }
}
