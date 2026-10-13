package zeromcp

import (
	"os"
	"path/filepath"
	"testing"
)

func resourceFixture(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "a.md"), []byte("# A"), 0644)
	os.MkdirAll(filepath.Join(dir, "sub"), 0755)
	os.WriteFile(filepath.Join(dir, "sub", "b.json"), []byte(`{"b":1}`), 0644)
	os.WriteFile(filepath.Join(dir, "c.bin"), []byte{0x00}, 0644)
	return dir
}

func TestResourceScannerStaticFiles(t *testing.T) {
	dir := resourceFixture(t)
	r := NewResourceScanner(Config{Resources: dir})
	r.Scan()

	want := map[string]struct{ uri, mime, desc string }{
		"a":     {"resource:///a.md", "text/markdown", "Static resource: a.md"},
		"sub_b": {"resource:///sub/b.json", "application/json", "Static resource: " + filepath.Join("sub", "b.json")},
		"c":     {"resource:///c.bin", "application/octet-stream", "Static resource: c.bin"},
	}
	if len(r.Resources) != len(want) {
		t.Fatalf("expected %d resources, got %v", len(want), r.Resources)
	}
	for name, w := range want {
		def, ok := r.Resources[name]
		if !ok {
			t.Errorf("missing resource %q", name)
			continue
		}
		if def.URI != w.uri || def.MimeType != w.mime || def.Description != w.desc {
			t.Errorf("%s: got uri=%q mime=%q desc=%q", name, def.URI, def.MimeType, def.Description)
		}
	}
}

func TestResourceScannerCustomSeparator(t *testing.T) {
	r := NewResourceScanner(Config{Resources: []any{resourceFixture(t)}, Separator: "."})
	r.Scan()
	if _, ok := r.Resources["sub.b"]; !ok {
		t.Errorf("expected sub.b, got %v", r.Resources)
	}
}

func TestResourceScannerUnsetMeansNoDirs(t *testing.T) {
	r := NewResourceScanner(Config{})
	r.Scan()
	if len(r.Resources) != 0 || len(r.Templates) != 0 {
		t.Errorf("expected nothing scanned, got %v %v", r.Resources, r.Templates)
	}
}

func TestResourceScannerRegisterAndRead(t *testing.T) {
	r := NewResourceScanner(Config{Resources: resourceFixture(t)})
	r.Scan()
	s := NewServer()
	r.RegisterAll(s)

	resp := s.HandleRequest(map[string]any{
		"jsonrpc": "2.0", "id": 1, "method": "resources/read",
		"params": map[string]any{"uri": "resource:///sub/b.json"},
	})
	result, _ := resp["result"].(map[string]any)
	contents, _ := result["contents"].([]any)
	if len(contents) != 1 {
		t.Fatalf("unexpected response %v", resp)
	}
	c := contents[0].(map[string]any)
	if c["text"] != `{"b":1}` || c["mimeType"] != "application/json" {
		t.Errorf("unexpected contents %v", c)
	}
}

func TestPromptScannerIgnoresNonPlugins(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "p.txt"), []byte("x"), 0644)
	os.WriteFile(filepath.Join(dir, "bad.so"), []byte("not a plugin"), 0644)
	p := NewPromptScanner(Config{Prompts: dir})
	p.Scan()
	if len(p.Prompts) != 0 {
		t.Errorf("expected no prompts, got %v", p.Prompts)
	}
}

func TestScannedName(t *testing.T) {
	cases := map[string]string{
		"a.md":                              "a",
		filepath.Join("sub", "b.json"):      "sub_b",
		"noext":                             "noext",
		filepath.Join("x", "y", "z.tar.gz"): "x_y_z.tar",
	}
	for in, want := range cases {
		if got := scannedName(in, "_"); got != want {
			t.Errorf("scannedName(%q) = %q, want %q", in, got, want)
		}
	}
}
