package commander

import (
	"os"
	"reflect"
	"testing"
)

// The store fsyncs twice per update. On macOS File.Sync is F_FULLFSYNC, which
// made long reconcile loops spend most of their time waiting on the disk.
// Tests cannot observe durability, so they skip the flush; the write, rename
// and directory open still run.
func TestMain(m *testing.M) {
	if reflect.ValueOf(syncFile).Pointer() != reflect.ValueOf((*os.File).Sync).Pointer() {
		panic("production syncFile must be File.Sync")
	}
	syncFile = func(*os.File) error { return nil }
	os.Exit(m.Run())
}
