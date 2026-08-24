package direct

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"strings"
	"time"
)

const (
	afcHeaderBytes       = 40
	afcMaximumPacketSize = 4 * 1024 * 1024
	afcWriteChunkBytes   = 1 * 1024 * 1024
	afcMagic             = "CFA6LPAA"

	afcStatus      uint64 = 0x01
	afcData        uint64 = 0x02
	afcFileOpen    uint64 = 0x0d
	afcFileOpenRes uint64 = 0x0e
	afcWrite       uint64 = 0x10
	afcFileClose   uint64 = 0x14
	afcRemovePath  uint64 = 0x08
	afcMakeDir     uint64 = 0x09
	afcGetFileInfo uint64 = 0x0a

	afcReadError uint64 = 4
)

type AFCError struct {
	Operation string
	Status    uint64
}

func (e *AFCError) Error() string {
	return fmt.Sprintf("afc %s failed with status %d", e.Operation, e.Status)
}

type AFCClient struct {
	conn     net.Conn
	deadline time.Time
	packet   uint64
	closed   bool
}

func NewAFCClient(conn net.Conn, deadline time.Time) *AFCClient {
	return &AFCClient{conn: conn, deadline: deadline, packet: 1}
}

func (c *AFCClient) Close() error {
	if c.closed {
		return nil
	}
	c.closed = true
	if c.conn == nil {
		return nil
	}
	err := c.conn.Close()
	c.conn = nil
	return err
}

func (c *AFCClient) Exists(path string) (bool, error) {
	if path == "" || !strings.HasPrefix(path, "/") || strings.Contains(path, "\x00") {
		return false, errors.New("invalid afc path")
	}
	operation, _, err := c.call(afcGetFileInfo, append([]byte(path), 0), "stat")
	if err != nil {
		var afcError *AFCError
		if errors.As(err, &afcError) && afcError.Status == afcReadError {
			return false, nil
		}
		return false, err
	}
	if operation != afcData {
		return false, errors.New("invalid afc stat response")
	}
	return true, nil
}

func (c *AFCClient) MakeDir(path string) error {
	if path == "" || !strings.HasPrefix(path, "/") || strings.Contains(path, "\x00") {
		return errors.New("invalid afc directory")
	}
	operation, payload, err := c.call(afcMakeDir, append([]byte(path), 0), "mkdir")
	if err != nil {
		var afcError *AFCError
		if errors.As(err, &afcError) && afcError.Status == 16 {
			return nil
		}
		return err
	}
	if operation == afcStatus {
		status, err := statusValue(payload)
		if err != nil {
			return err
		}
		if status == 16 { // object already exists
			return nil
		}
		return &AFCError{Operation: "mkdir", Status: status}
	}
	return errors.New("invalid afc mkdir response")
}

func (c *AFCClient) Remove(path string) error {
	if path == "" || !strings.HasPrefix(path, "/") || strings.Contains(path, "\x00") {
		return errors.New("invalid afc path")
	}
	operation, payload, err := c.call(afcRemovePath, append([]byte(path), 0), "remove")
	if err != nil {
		return err
	}
	return c.requireStatus(operation, payload, "remove")
}

func (c *AFCClient) Open(path string) (uint64, error) {
	if path == "" || !strings.HasPrefix(path, "/") || strings.Contains(path, "\x00") {
		return 0, errors.New("invalid afc path")
	}
	payload := make([]byte, 8+len(path)+1)
	binary.LittleEndian.PutUint64(payload, 3) // AFC_FOPEN_WRONLY
	copy(payload[8:], path)
	operation, response, err := c.call(afcFileOpen, payload, "open")
	if err != nil {
		return 0, err
	}
	if operation != afcFileOpenRes || len(response) != 8 {
		return 0, errors.New("invalid afc open response")
	}
	return binary.LittleEndian.Uint64(response), nil
}

func (c *AFCClient) Write(handle uint64, data []byte) error {
	if handle == 0 || len(data) == 0 || len(data) > afcWriteChunkBytes {
		return errors.New("invalid afc write")
	}
	payload := make([]byte, 8+len(data))
	binary.LittleEndian.PutUint64(payload, handle)
	copy(payload[8:], data)
	operation, response, err := c.callWithThisLength(afcWrite, payload, "write", afcHeaderBytes+8)
	if err != nil {
		return err
	}
	return c.requireStatus(operation, response, "write")
}

func (c *AFCClient) CloseFile(handle uint64) error {
	if handle == 0 {
		return errors.New("invalid afc handle")
	}
	payload := make([]byte, 8)
	binary.LittleEndian.PutUint64(payload, handle)
	operation, response, err := c.call(afcFileClose, payload, "close")
	if err != nil {
		return err
	}
	return c.requireStatus(operation, response, "close")
}

func (c *AFCClient) Upload(path string, source io.ReaderAt, size int64) (uint64, error) {
	if size <= 0 || source == nil {
		return 0, errors.New("invalid afc upload source")
	}
	handle, err := c.Open(path)
	if err != nil {
		return 0, err
	}
	completed := false
	defer func() {
		if !completed {
			_ = c.CloseFile(handle)
		}
	}()
	buffer := make([]byte, afcWriteChunkBytes)
	for offset := int64(0); offset < size; {
		count := int64(len(buffer))
		if remaining := size - offset; remaining < count {
			count = remaining
		}
		read, readErr := source.ReadAt(buffer[:count], offset)
		if readErr != nil && !(readErr == io.EOF && int64(read) == count) {
			return 0, readErr
		}
		if int64(read) != count {
			return 0, io.ErrUnexpectedEOF
		}
		if err := c.Write(handle, buffer[:read]); err != nil {
			return 0, err
		}
		offset += count
	}
	completed = true
	return handle, nil
}

func (c *AFCClient) call(operation uint64, payload []byte, name string) (uint64, []byte, error) {
	return c.callWithThisLength(operation, payload, name, 0)
}

func (c *AFCClient) callWithThisLength(operation uint64, payload []byte, name string, thisLength uint64) (uint64, []byte, error) {
	if c.closed || c.conn == nil {
		return 0, nil, errors.New("afc connection closed")
	}
	if len(payload)+afcHeaderBytes > afcMaximumPacketSize {
		return 0, nil, errors.New("afc packet cap")
	}
	entireLength := uint64(afcHeaderBytes + len(payload))
	if thisLength == 0 {
		thisLength = entireLength
	}
	if thisLength < afcHeaderBytes || thisLength > entireLength {
		return 0, nil, errors.New("invalid afc request header")
	}
	packet := c.packet
	c.packet++
	header := make([]byte, afcHeaderBytes)
	copy(header[:8], afcMagic)
	binary.LittleEndian.PutUint64(header[8:16], entireLength)
	binary.LittleEndian.PutUint64(header[16:24], thisLength)
	binary.LittleEndian.PutUint64(header[24:32], packet)
	binary.LittleEndian.PutUint64(header[32:40], operation)
	if err := writeDeadline(c.conn, append(header, payload...), c.deadline); err != nil {
		return 0, nil, err
	}
	responseHeader := make([]byte, afcHeaderBytes)
	if err := readDeadline(c.conn, responseHeader, c.deadline); err != nil {
		return 0, nil, err
	}
	if string(responseHeader[:8]) != afcMagic {
		return 0, nil, errors.New("invalid afc magic")
	}
	entire := binary.LittleEndian.Uint64(responseHeader[8:16])
	responseThisLength := binary.LittleEndian.Uint64(responseHeader[16:24])
	responsePacket := binary.LittleEndian.Uint64(responseHeader[24:32])
	responseOperation := binary.LittleEndian.Uint64(responseHeader[32:40])
	if responsePacket != packet || entire < afcHeaderBytes || responseThisLength < afcHeaderBytes ||
		responseThisLength > entire || entire > afcMaximumPacketSize {
		return 0, nil, errors.New("invalid afc response header")
	}
	response := make([]byte, int(entire-afcHeaderBytes))
	if err := readDeadline(c.conn, response, c.deadline); err != nil {
		return 0, nil, err
	}
	if responseOperation == afcStatus {
		status, err := statusValue(response)
		if err != nil {
			return 0, nil, err
		}
		if status != 0 {
			return responseOperation, response, &AFCError{Operation: name, Status: status}
		}
	}
	return responseOperation, response, nil
}

func (c *AFCClient) requireStatus(operation uint64, payload []byte, name string) error {
	if operation != afcStatus {
		return errors.New("invalid afc status response")
	}
	status, err := statusValue(payload)
	if err != nil {
		return err
	}
	if status != 0 {
		return &AFCError{Operation: name, Status: status}
	}
	return nil
}

func statusValue(payload []byte) (uint64, error) {
	if len(payload) != 8 {
		return 0, errors.New("invalid afc status payload")
	}
	return binary.LittleEndian.Uint64(payload), nil
}
