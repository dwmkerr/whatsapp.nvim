package main

import (
	"bufio"
	"encoding/json"
	"io"
	"sync"
)

// Request is one line of JSON on stdin from the editor.
type Request struct {
	ID     int64           `json:"id"`
	Method string          `json:"method"`
	Params json.RawMessage `json:"params,omitempty"`
}

// Response answers a Request. Exactly one of Result or Error is set.
type Response struct {
	ID     int64       `json:"id"`
	Result interface{} `json:"result,omitempty"`
	Error  string      `json:"error,omitempty"`
}

// Event is an unsolicited message from the bridge to the editor.
type Event struct {
	Event string      `json:"event"`
	Data  interface{} `json:"data,omitempty"`
}

// Writer serialises JSON lines to stdout. Events arrive from whatsmeow
// goroutines while responses come from the request loop, so writes need a
// mutex to keep lines intact.
type Writer struct {
	mu  sync.Mutex
	enc *json.Encoder
	w   *bufio.Writer
}

func NewWriter(w io.Writer) *Writer {
	bw := bufio.NewWriter(w)
	return &Writer{enc: json.NewEncoder(bw), w: bw}
}

func (w *Writer) send(v interface{}) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if err := w.enc.Encode(v); err != nil {
		return
	}
	_ = w.w.Flush()
}

func (w *Writer) Respond(id int64, result interface{}) {
	w.send(Response{ID: id, Result: result})
}

func (w *Writer) Fail(id int64, err error) {
	w.send(Response{ID: id, Error: err.Error()})
}

func (w *Writer) Emit(event string, data interface{}) {
	w.send(Event{Event: event, Data: data})
}

// ReadRequests decodes one request per line until stdin closes.
func ReadRequests(r io.Reader, handle func(Request)) error {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 0, 64*1024), 16*1024*1024)
	for sc.Scan() {
		line := sc.Bytes()
		if len(line) == 0 {
			continue
		}
		var req Request
		if err := json.Unmarshal(line, &req); err != nil {
			continue
		}
		handle(req)
	}
	return sc.Err()
}
