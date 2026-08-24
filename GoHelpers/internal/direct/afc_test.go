package direct

import (
	"bytes"
	"encoding/binary"
	"io"
	"net"
	"testing"
	"time"
)

func TestAFCClientUsesExpectedPacketFraming(t *testing.T) {
	clientConn, serverConn := net.Pipe()
	defer serverConn.Close()
	deadline := time.Now().Add(time.Second)
	serverError := make(chan error, 1)
	go func() {
		for index := 0; index < 3; index++ {
			header := make([]byte, afcHeaderBytes)
			if _, err := io.ReadFull(serverConn, header); err != nil {
				serverError <- err
				return
			}
			if string(header[:8]) != afcMagic {
				serverError <- &AFCError{Operation: "header"}
				return
			}
			length := binary.LittleEndian.Uint64(header[8:16])
			thisLength := binary.LittleEndian.Uint64(header[16:24])
			payload := make([]byte, int(length)-afcHeaderBytes)
			if _, err := io.ReadFull(serverConn, payload); err != nil {
				serverError <- err
				return
			}
			if binary.LittleEndian.Uint64(header[24:32]) != uint64(index+1) {
				serverError <- &AFCError{Operation: "packet"}
				return
			}
			operation := binary.LittleEndian.Uint64(header[32:40])
			responseOperation := afcStatus
			responsePayload := make([]byte, 8)
			if index == 0 {
				if thisLength != length || operation != afcFileOpen || string(payload[8:]) != "/tmp/a.ipa\x00" {
					serverError <- &AFCError{Operation: "open"}
					return
				}
				responseOperation = afcFileOpenRes
				binary.LittleEndian.PutUint64(responsePayload, 41)
			} else if index == 1 {
				if operation != afcWrite || thisLength != afcHeaderBytes+8 || binary.LittleEndian.Uint64(payload[:8]) != 41 || string(payload[8:]) != "abc" {
					serverError <- &AFCError{Operation: "write"}
					return
				}
			} else if thisLength != length || operation != afcFileClose || binary.LittleEndian.Uint64(payload) != 41 {
				serverError <- &AFCError{Operation: "close"}
				return
			}
			responseHeader := make([]byte, afcHeaderBytes)
			copy(responseHeader[:8], afcMagic)
			binary.LittleEndian.PutUint64(responseHeader[8:16], uint64(afcHeaderBytes+len(responsePayload)))
			binary.LittleEndian.PutUint64(responseHeader[16:24], uint64(afcHeaderBytes+len(responsePayload)))
			binary.LittleEndian.PutUint64(responseHeader[24:32], uint64(index+1))
			binary.LittleEndian.PutUint64(responseHeader[32:40], responseOperation)
			if _, err := serverConn.Write(append(responseHeader, responsePayload...)); err != nil {
				serverError <- err
				return
			}
		}
		serverError <- nil
	}()

	client := NewAFCClient(clientConn, deadline)
	handle, err := client.Open("/tmp/a.ipa")
	if err != nil {
		t.Fatal(err)
	}
	if handle != 41 {
		t.Fatalf("handle = %d", handle)
	}
	if err := client.Write(handle, []byte("abc")); err != nil {
		t.Fatal(err)
	}
	if err := client.CloseFile(handle); err != nil {
		t.Fatal(err)
	}
	if err := <-serverError; err != nil {
		t.Fatal(err)
	}
}

func TestAFCClientExistsMatchesPythonReadErrorSemantics(t *testing.T) {
	for _, test := range []struct {
		name      string
		operation uint64
		payload   []byte
		want      bool
		wantError bool
	}{
		{name: "existing", operation: afcData, payload: []byte("st_ifmt\x00S_IFDIR\x00"), want: true},
		{name: "missing", operation: afcStatus, payload: uint64Payload(afcReadError), want: false},
	} {
		t.Run(test.name, func(t *testing.T) {
			clientConn, serverConn := net.Pipe()
			defer serverConn.Close()
			serverError := make(chan error, 1)
			go func() {
				header := make([]byte, afcHeaderBytes)
				if _, err := io.ReadFull(serverConn, header); err != nil {
					serverError <- err
					return
				}
				if operation := binary.LittleEndian.Uint64(header[32:40]); operation != afcGetFileInfo {
					serverError <- &AFCError{Operation: "stat operation"}
					return
				}
				length := binary.LittleEndian.Uint64(header[8:16])
				payload := make([]byte, int(length)-afcHeaderBytes)
				if _, err := io.ReadFull(serverConn, payload); err != nil {
					serverError <- err
					return
				}
				if string(payload) != "/PublicStaging/PulsePhone\x00" {
					serverError <- &AFCError{Operation: "stat path"}
					return
				}
				response := make([]byte, afcHeaderBytes)
				copy(response[:8], afcMagic)
				binary.LittleEndian.PutUint64(response[8:16], uint64(afcHeaderBytes+len(test.payload)))
				binary.LittleEndian.PutUint64(response[16:24], uint64(afcHeaderBytes+len(test.payload)))
				binary.LittleEndian.PutUint64(response[24:32], binary.LittleEndian.Uint64(header[24:32]))
				binary.LittleEndian.PutUint64(response[32:40], test.operation)
				_, err := serverConn.Write(append(response, test.payload...))
				serverError <- err
			}()
			client := NewAFCClient(clientConn, time.Now().Add(time.Second))
			got, err := client.Exists("/PublicStaging/PulsePhone")
			if (err != nil) != test.wantError || got != test.want {
				t.Fatalf("Exists() = %t, %v", got, err)
			}
			if err := <-serverError; err != nil {
				t.Fatal(err)
			}
		})
	}
}

func uint64Payload(value uint64) []byte {
	payload := make([]byte, 8)
	binary.LittleEndian.PutUint64(payload, value)
	return payload
}

func TestAFCUploadRequiresExplicitFinalizeBeforeContinuing(t *testing.T) {
	clientConn, serverConn := net.Pipe()
	defer serverConn.Close()
	deadline := time.Now().Add(time.Second)
	writesComplete := make(chan struct{})
	allowClose := make(chan struct{})
	serverError := make(chan error, 1)
	go func() {
		defer func() {
			if recovered := recover(); recovered != nil {
				serverError <- &AFCError{Operation: "server panic"}
			}
		}()
		for index := 0; index < 3; index++ {
			header := make([]byte, afcHeaderBytes)
			if _, err := io.ReadFull(serverConn, header); err != nil {
				serverError <- err
				return
			}
			length := binary.LittleEndian.Uint64(header[8:16])
			thisLength := binary.LittleEndian.Uint64(header[16:24])
			payload := make([]byte, int(length)-afcHeaderBytes)
			if _, err := io.ReadFull(serverConn, payload); err != nil {
				serverError <- err
				return
			}
			operation := binary.LittleEndian.Uint64(header[32:40])
			responseOperation := afcStatus
			responsePayload := make([]byte, 8)
			switch index {
			case 0:
				if operation != afcFileOpen {
					serverError <- &AFCError{Operation: "open"}
					return
				}
				responseOperation = afcFileOpenRes
				binary.LittleEndian.PutUint64(responsePayload, 17)
			case 1:
				if thisLength != afcHeaderBytes+8 || operation != afcWrite || binary.LittleEndian.Uint64(payload[:8]) != 17 || !bytes.Equal(payload[8:], []byte("ipa")) {
					serverError <- &AFCError{Operation: "write"}
					return
				}
			case 2:
				if thisLength != length || operation != afcFileClose || binary.LittleEndian.Uint64(payload) != 17 {
					serverError <- &AFCError{Operation: "close"}
					return
				}
			}
			responseHeader := make([]byte, afcHeaderBytes)
			copy(responseHeader[:8], afcMagic)
			binary.LittleEndian.PutUint64(responseHeader[8:16], uint64(afcHeaderBytes+len(responsePayload)))
			binary.LittleEndian.PutUint64(responseHeader[16:24], uint64(afcHeaderBytes+len(responsePayload)))
			binary.LittleEndian.PutUint64(responseHeader[24:32], uint64(index+1))
			binary.LittleEndian.PutUint64(responseHeader[32:40], responseOperation)
			if _, err := serverConn.Write(append(responseHeader, responsePayload...)); err != nil {
				serverError <- err
				return
			}
			if index == 1 {
				close(writesComplete)
				<-allowClose
			}
		}
		serverError <- nil
	}()

	type uploadResult struct {
		handle uint64
		err    error
	}
	uploaded := make(chan uploadResult, 1)
	client := NewAFCClient(clientConn, deadline)
	go func() {
		handle, err := client.Upload("/tmp/a.ipa", bytes.NewReader([]byte("ipa")), 3)
		uploaded <- uploadResult{handle: handle, err: err}
	}()
	select {
	case <-writesComplete:
	case <-time.After(time.Second):
		t.Fatal("AFC upload did not write the source")
	}
	select {
	case result := <-uploaded:
		if result.err != nil || result.handle != 17 {
			t.Fatalf("upload result = %#v", result)
		}
		close(allowClose)
		if err := client.CloseFile(result.handle); err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("AFC upload finalized the remote file before its caller could classify finalize errors")
	}
	if err := <-serverError; err != nil {
		t.Fatal(err)
	}
}

func TestAFCUploadSplitsSourceAtOneMiBBoundary(t *testing.T) {
	payload := append(bytes.Repeat([]byte{'x'}, afcWriteChunkBytes), bytes.Repeat([]byte{'y'}, 17)...)
	clientConn, serverConn := net.Pipe()
	defer serverConn.Close()
	deadline := time.Now().Add(time.Second)
	serverError := make(chan error, 1)
	go func() {
		defer serverConn.Close()
		for index, wantOperation := range []uint64{afcFileOpen, afcWrite, afcWrite, afcFileClose} {
			header := make([]byte, afcHeaderBytes)
			if _, err := io.ReadFull(serverConn, header); err != nil {
				serverError <- err
				return
			}
			length := binary.LittleEndian.Uint64(header[8:16])
			thisLength := binary.LittleEndian.Uint64(header[16:24])
			request := make([]byte, int(length)-afcHeaderBytes)
			if _, err := io.ReadFull(serverConn, request); err != nil {
				serverError <- err
				return
			}
			if operation := binary.LittleEndian.Uint64(header[32:40]); operation != wantOperation {
				serverError <- &AFCError{Operation: "unexpected operation"}
				return
			}
			switch index {
			case 0:
				if thisLength != length || string(request[8:]) != "/tmp/boundary.ipa\x00" {
					serverError <- &AFCError{Operation: "open path"}
					return
				}
			case 1:
				if thisLength != afcHeaderBytes+8 || binary.LittleEndian.Uint64(request[:8]) != 23 || !bytes.Equal(request[8:], payload[:afcWriteChunkBytes]) {
					serverError <- &AFCError{Operation: "first upload chunk"}
					return
				}
			case 2:
				if thisLength != afcHeaderBytes+8 || binary.LittleEndian.Uint64(request[:8]) != 23 || !bytes.Equal(request[8:], payload[afcWriteChunkBytes:]) {
					serverError <- &AFCError{Operation: "second upload chunk"}
					return
				}
			case 3:
				if thisLength != length || binary.LittleEndian.Uint64(request) != 23 {
					serverError <- &AFCError{Operation: "close handle"}
					return
				}
			}
			responseOperation := afcStatus
			responsePayload := make([]byte, 8)
			if index == 0 {
				responseOperation = afcFileOpenRes
				binary.LittleEndian.PutUint64(responsePayload, 23)
			}
			responseHeader := make([]byte, afcHeaderBytes)
			copy(responseHeader[:8], afcMagic)
			binary.LittleEndian.PutUint64(responseHeader[8:16], uint64(afcHeaderBytes+len(responsePayload)))
			binary.LittleEndian.PutUint64(responseHeader[16:24], uint64(afcHeaderBytes+len(responsePayload)))
			binary.LittleEndian.PutUint64(responseHeader[24:32], uint64(index+1))
			binary.LittleEndian.PutUint64(responseHeader[32:40], responseOperation)
			if _, err := serverConn.Write(append(responseHeader, responsePayload...)); err != nil {
				serverError <- err
				return
			}
		}
		serverError <- nil
	}()

	client := NewAFCClient(clientConn, deadline)
	defer client.Close()
	handle, err := client.Upload("/tmp/boundary.ipa", bytes.NewReader(payload), int64(len(payload)))
	if err != nil || handle != 23 {
		t.Fatalf("upload = handle=%d err=%v", handle, err)
	}
	if err := client.CloseFile(handle); err != nil {
		t.Fatal(err)
	}
	if err := <-serverError; err != nil {
		t.Fatal(err)
	}
}
