// Command go-cache implements Go's GOCACHEPROG protocol using a private,
// process-local action index. It deliberately uses no file locks or network.
package main

import (
	"bufio"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
)

// Stream artifact bodies rather than allocating them under the compiler's
// 1 GiB memory cap. Bound metadata, individual artifacts, and total disk use.
const (
	maxRequest = 16 << 10
	maxBody    = 512 << 20
	maxStored  = 768 << 20
	maxActions = 65536
)

type request struct {
	ID       int64
	Command  string
	ActionID []byte
	OutputID []byte
	BodySize int64
}
type response struct {
	ID            int64
	Err           string   `json:",omitempty"`
	KnownCommands []string `json:",omitempty"`
	Miss          bool     `json:",omitempty"`
	OutputID      []byte   `json:",omitempty"`
	Size          int64    `json:",omitempty"`
	DiskPath      string   `json:",omitempty"`
}
type entry struct {
	output []byte
	size   int64
	path   string
}

func main() {
	cache := os.Getenv("GOCACHE")
	if cache == "" || !filepath.IsAbs(cache) {
		fmt.Fprintln(os.Stderr, "go-cache: GOCACHE must be an absolute directory")
		os.Exit(1)
	}
	if err := serve(os.Stdin, os.Stdout, filepath.Join(cache, "athena-cache")); err != nil {
		fmt.Fprintln(os.Stderr, "go-cache:", err)
		os.Exit(1)
	}
}

// Files survive close: the go command can still consume returned DiskPaths.
// The sandbox lifecycle removes this directory after the build completes.
func serve(input io.Reader, output io.Writer, root string) error {
	if err := os.MkdirAll(root, 0700); err != nil {
		return err
	}
	dir, err := os.MkdirTemp(root, "build-")
	if err != nil {
		return err
	}
	reader := bufio.NewReader(input)
	encoder := json.NewEncoder(output)
	if err := encoder.Encode(response{KnownCommands: []string{"get", "put", "close"}}); err != nil {
		return err
	}
	actions := make(map[string]entry)
	var stored int64
	for {
		line, err := readRequest(reader)
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		var req request
		if err := json.Unmarshal(line, &req); err != nil {
			return fmt.Errorf("invalid request: %w", err)
		}
		res := response{ID: req.ID}
		switch req.Command {
		case "close":
			return encoder.Encode(res)
		case "get":
			if hit, ok := actions[string(req.ActionID)]; ok {
				res.OutputID, res.Size, res.DiskPath = hit.output, hit.size, hit.path
			} else {
				res.Miss = true
			}
		case "put":
			// Protocol violations are fatal: continuing could interpret body bytes as
			// requests. Report the correlated error before terminating.
			if req.BodySize < 0 || req.BodySize > maxBody || stored+req.BodySize > maxStored || len(actions) >= maxActions || len(req.ActionID) != 32 || len(req.OutputID) != 32 {
				res.Err = "cache request exceeds limits or has invalid IDs"
				if err := encoder.Encode(res); err != nil {
					return err
				}
				return errors.New(res.Err)
			}
			path, err := storeBody(reader, dir, req)
			if err != nil {
				res.Err = err.Error()
				if writeErr := encoder.Encode(res); writeErr != nil {
					return writeErr
				}
				return err
			}
			stored += req.BodySize
			actions[string(req.ActionID)] = entry{req.OutputID, req.BodySize, path}
			res.DiskPath = path
		default:
			res.Err = "unsupported command"
		}
		if err := encoder.Encode(res); err != nil {
			return err
		}
	}
}

func readRequest(reader *bufio.Reader) ([]byte, error) {
	var line []byte
	for {
		part, prefix, err := reader.ReadLine()
		if err != nil {
			return nil, err
		}
		if len(line)+len(part) > maxRequest {
			return nil, errors.New("request metadata exceeds limit")
		}
		line = append(line, part...)
		if !prefix {
			if len(line) == 0 {
				continue
			}
			return line, nil
		}
	}
}

func storeBody(reader *bufio.Reader, dir string, req request) (path string, err error) {
	file, err := os.CreateTemp(dir, "artifact-")
	if err != nil {
		return "", err
	}
	temp := file.Name()
	defer func() {
		file.Close()
		if err != nil {
			os.Remove(temp)
		}
	}()
	if req.BodySize > 0 {
		quote, readErr := reader.ReadByte()
		for readErr == nil && (quote == '\n' || quote == '\r' || quote == ' ' || quote == '\t') {
			quote, readErr = reader.ReadByte()
		}
		if readErr != nil || quote != '"' {
			return "", errors.New("missing body string")
		}
		encodedSize := (req.BodySize + 2) / 3 * 4
		decoder := base64.NewDecoder(base64.StdEncoding, io.LimitReader(reader, encodedSize))
		count, copyErr := io.Copy(file, decoder)
		if copyErr != nil || count != req.BodySize {
			return "", errors.New("invalid base64 body or body size mismatch")
		}
		quote, readErr = reader.ReadByte()
		if readErr != nil || quote != '"' {
			return "", errors.New("missing body terminator")
		}
		newline, readErr := reader.ReadByte()
		if readErr != nil || newline != '\n' {
			return "", errors.New("missing body newline")
		}
	}
	if err = file.Close(); err != nil {
		return "", err
	}
	path = filepath.Join(dir, hex.EncodeToString(req.OutputID))
	if err = os.Rename(temp, path); err != nil {
		return "", err
	}
	return path, nil
}
