package main

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// Match the SDK writer, including the blank line following each request and
// the separate JSON base64 string (not a Body property on the request).
func protocol(reqs ...interface{}) string {
	var out bytes.Buffer
	enc := json.NewEncoder(&out)
	for _, req := range reqs {
		_ = enc.Encode(req)
		out.WriteByte('\n')
	}
	return out.String()
}
func replies(t *testing.T, out *bytes.Buffer) []response {
	t.Helper()
	var result []response
	dec := json.NewDecoder(out)
	for {
		var r response
		err := dec.Decode(&r)
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		result = append(result, r)
	}
	return result
}
func TestProtocolRoundTrip(t *testing.T) {
	for _, body := range [][]byte{nil, []byte("hello 世界\x00\xff"), bytes.Repeat([]byte("artifact"), 20000)} {
		t.Run(strconv.Itoa(len(body)), func(t *testing.T) {
			action := bytes.Repeat([]byte{1}, 32)
			output := bytes.Repeat([]byte{2}, 32)
			var input strings.Builder
			input.WriteString(protocol(request{ID: 1, Command: "get", ActionID: action}, request{ID: 2, Command: "put", ActionID: action, OutputID: output, BodySize: int64(len(body))}))
			if len(body) > 0 {
				encoded, _ := json.Marshal(body)
				input.Write(encoded)
				input.WriteByte('\n')
			}
			input.WriteString(protocol(request{ID: 3, Command: "get", ActionID: action}, request{ID: 4, Command: "close"}))
			var out bytes.Buffer
			root := filepath.Join(t.TempDir(), "athena-cache")
			if err := serve(strings.NewReader(input.String()), &out, root); err != nil {
				t.Fatal(err)
			}
			got := replies(t, &out)
			if len(got) != 5 || strings.Join(got[0].KnownCommands, ",") != "get,put,close" || !got[1].Miss || got[4].ID != 4 {
				t.Fatalf("bad replies: %+v", got)
			}
			hit := got[3]
			if hit.ID != 3 || hit.Miss || !bytes.Equal(hit.OutputID, output) || hit.Size != int64(len(body)) || hit.DiskPath != got[2].DiskPath || !filepath.IsAbs(hit.DiskPath) {
				t.Fatalf("bad hit: %+v", hit)
			}
			content, err := os.ReadFile(hit.DiskPath)
			if err != nil || !bytes.Equal(content, body) {
				t.Fatalf("artifact lost after close: %v", err)
			}
			info, err := os.Stat(filepath.Dir(hit.DiskPath))
			if err != nil {
				t.Fatal(err)
			}
			if info.Mode().Perm() != 0700 {
				t.Fatalf("directory permissions: %v", info.Mode())
			}
			info, err = os.Stat(hit.DiskPath)
			if err != nil {
				t.Fatal(err)
			}
			if info.Mode().Perm() != 0600 {
				t.Fatalf("artifact permissions: %v", info.Mode())
			}
		})
	}
}
func TestMalformedBodiesFailWithoutPublishing(t *testing.T) {
	for _, body := range []string{"\"!!!!\"\n", "\"YWJj\"\n", "\"YQ==x\n", "\"YQ==\"x"} {
		t.Run(body, func(t *testing.T) {
			req := request{ID: 9, Command: "put", ActionID: make([]byte, 32), OutputID: make([]byte, 32), BodySize: 1}
			root := t.TempDir()
			var out bytes.Buffer
			if err := serve(strings.NewReader(protocol(req)+body), &out, root); err == nil {
				t.Fatal("accepted invalid body")
			}
			got := replies(t, &out)
			if len(got) != 2 || got[1].ID != 9 || got[1].Err == "" {
				t.Fatalf("missing correlated error: %+v", got)
			}
			files, _ := filepath.Glob(filepath.Join(root, "build-*", "*"))
			if len(files) != 0 {
				t.Fatalf("partial artifacts: %v", files)
			}
		})
	}
}
func TestRejectOversizeRequestsBeforeReadingBody(t *testing.T) {
	for _, size := range []int64{-1, maxBody + 1} {
		var out bytes.Buffer
		err := serve(strings.NewReader(protocol(request{ID: 7, Command: "put", ActionID: make([]byte, 32), OutputID: make([]byte, 32), BodySize: size})), &out, t.TempDir())
		if err == nil {
			t.Fatal("accepted invalid size")
		}
		got := replies(t, &out)
		if got[1].ID != 7 || got[1].Err == "" {
			t.Fatal("missing protocol error")
		}
	}
	var out bytes.Buffer
	if err := serve(strings.NewReader(strings.Repeat("x", maxRequest+1)), &out, t.TempDir()); err == nil {
		t.Fatal("accepted oversized metadata")
	}
}
func TestNewProcessDoesNotReuseActionIndex(t *testing.T) {
	root := t.TempDir()
	var first, second bytes.Buffer
	req := request{ID: 1, Command: "put", ActionID: make([]byte, 32), OutputID: make([]byte, 32)}
	if err := serve(strings.NewReader(protocol(req, request{ID: 2, Command: "close"})), &first, root); err != nil {
		t.Fatal(err)
	}
	if err := serve(strings.NewReader(protocol(request{ID: 3, Command: "get", ActionID: req.ActionID}, request{ID: 4, Command: "close"})), &second, root); err != nil {
		t.Fatal(err)
	}
	if !replies(t, &second)[1].Miss {
		t.Fatal("reused previous process index")
	}
}
