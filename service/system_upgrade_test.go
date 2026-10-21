package service

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/QuantumNous/new-api/common"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func setUpSystemUpgradeDir(t *testing.T, agentAge time.Duration) (string, time.Time) {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("UPGRADE_CONTROL_DIR", dir)
	now := time.Date(2026, 10, 22, 10, 0, 0, 0, time.UTC)
	if agentAge >= 0 {
		writeSystemUpgradeTestFile(t, dir, systemUpgradeAgentFile, systemUpgradeAgent{
			Version: "1", UpdatedAt: now.Add(-agentAge).Format(time.RFC3339),
		})
	}
	return dir, now
}

func writeSystemUpgradeTestFile(t *testing.T, dir, name string, v any) {
	t.Helper()
	data, err := common.Marshal(v)
	require.NoError(t, err)
	require.NoError(t, os.WriteFile(filepath.Join(dir, name), data, 0o644))
}

func TestCompareSystemVersionsMatchesConsoleOrdering(t *testing.T) {
	tests := []struct {
		left, right string
		want        int
		ok          bool
	}{
		{"v1.0.0-rc.44", "v1.0.0-rc.44-ace.1", -1, true},
		{"v1.0.0-rc.44-ace.1", "v1.0.0-rc.44-ace.2", -1, true},
		{"v1.0.0-rc.44-ace.9", "v1.0.0-rc.44-ace.10", -1, true},
		{"v1.0.0-rc.44-ace.2", "v1.0.0-rc.45", -1, true},
		{"v1.0.0", "v1.0.0-ace.1", -1, true},
		{"v1.0.0-rc.36", "v1.0.0", -1, true},
		{"v0.13.1-patch.1", "v0.13.2", -1, true},
		{"v0.9.3.0", "v0.9.3", 0, true},
		{"v1.0.0-rc.44-ace.2", "v1.0.0-rc.44-ace.2", 0, true},
		{"v1.0.0-rc.44-ace.2", "v1.0.0-rc.44-ace.1", 1, true},
		{"", "v1.0.0-ace.1", 0, false},
		{"v0.0.0", "v1.0.0-ace.1", 0, false},
		{"v1.0.0-ace.0", "v1.0.0-ace.1", 0, false},
	}
	for _, tt := range tests {
		got, ok := CompareSystemVersions(tt.left, tt.right)
		assert.Equal(t, tt.ok, ok, "%s vs %s", tt.left, tt.right)
		assert.Equal(t, tt.want, got, "%s vs %s", tt.left, tt.right)
	}
}

func TestSystemUpgradeIsDisabledWithoutControlDir(t *testing.T) {
	t.Setenv("UPGRADE_CONTROL_DIR", "")

	assert.Equal(t, SystemUpgradeState{}, GetSystemUpgradeState(time.Now()))
	_, err := RequestSystemUpgrade("v1.0.0-rc.44-ace.3", "v1.0.0-rc.44-ace.2", 1, time.Now())
	assert.ErrorIs(t, err, ErrSystemUpgradeDisabled)
}

func TestSystemUpgradeRequiresFreshAgentHeartbeat(t *testing.T) {
	tests := []struct {
		name     string
		agentAge time.Duration
		online   bool
	}{
		{"recent heartbeat", 30 * time.Second, true},
		{"stale heartbeat", 4 * time.Minute, false},
		{"agent never ran", -1, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			dir, now := setUpSystemUpgradeDir(t, tt.agentAge)

			state := GetSystemUpgradeState(now)
			assert.True(t, state.Enabled)
			assert.Equal(t, tt.online, state.AgentOnline)

			_, err := RequestSystemUpgrade("v1.0.0-rc.44-ace.3", "v1.0.0-rc.44-ace.2", 1, now)
			if tt.online {
				require.NoError(t, err)
				return
			}
			assert.ErrorIs(t, err, ErrSystemUpgradeAgentOffline)
			assert.NoFileExists(t, filepath.Join(dir, systemUpgradeRequestFile))
		})
	}
}

func TestSystemUpgradeRejectsTagsTheAgentWouldRefuse(t *testing.T) {
	for _, tag := range []string{
		"v1.0.0-rc.45",
		"ghcr.io/other/new-api:v1.0.0-ace.1",
		"v1.0.0-ace.1;touch /tmp/x",
		"v1.0.0-ace.0",
		"../v1.0.0-ace.1",
		"",
	} {
		dir, now := setUpSystemUpgradeDir(t, time.Second)

		_, err := RequestSystemUpgrade(tag, "v1.0.0-rc.44-ace.2", 1, now)

		assert.ErrorIs(t, err, ErrSystemUpgradeInvalidTag, "tag %q", tag)
		assert.NoFileExists(t, filepath.Join(dir, systemUpgradeRequestFile), "tag %q", tag)
	}
}

func TestSystemUpgradeRejectsVersionsThatAreNotNewer(t *testing.T) {
	for _, tag := range []string{"v1.0.0-rc.44-ace.2", "v1.0.0-rc.44-ace.1"} {
		_, now := setUpSystemUpgradeDir(t, time.Second)

		_, err := RequestSystemUpgrade(tag, "v1.0.0-rc.44-ace.2", 1, now)

		assert.ErrorIs(t, err, ErrSystemUpgradeNotNewer, "tag %q", tag)
	}
}

func TestSystemUpgradeWritesOnlyTheRequestFields(t *testing.T) {
	dir, now := setUpSystemUpgradeDir(t, time.Second)

	status, err := RequestSystemUpgrade(" v1.0.0-rc.44-ace.3 ", "v1.0.0-rc.44-ace.2", 7, now)
	require.NoError(t, err)

	data, err := os.ReadFile(filepath.Join(dir, systemUpgradeRequestFile))
	require.NoError(t, err)
	var raw map[string]any
	require.NoError(t, common.Unmarshal(data, &raw))
	assert.Equal(t, map[string]any{
		"id":           status.Id,
		"tag":          "v1.0.0-rc.44-ace.3",
		"requested_by": float64(7),
		"requested_at": "2026-10-22T10:00:00Z",
	}, raw)
	assert.Equal(t, SystemUpgradePhaseQueued, status.Phase)
	assert.Equal(t, "v1.0.0-rc.44-ace.2", status.FromVersion)
	assert.Equal(t, status, GetSystemUpgradeState(now).Status)
}

func TestSystemUpgradeAllowsOneRunAtATime(t *testing.T) {
	tests := []struct {
		name    string
		phase   string
		age     time.Duration
		blocked bool
	}{
		{"queued request", SystemUpgradePhaseQueued, time.Minute, true},
		{"running upgrade", SystemUpgradePhaseRecreating, 5 * time.Minute, true},
		{"finished upgrade", SystemUpgradePhaseSucceeded, time.Minute, false},
		{"failed upgrade", SystemUpgradePhaseFailed, time.Minute, false},
		{"queued request the agent never picked up", SystemUpgradePhaseQueued, 6 * time.Minute, false},
		{"running upgrade that stopped reporting", SystemUpgradePhasePulling, 21 * time.Minute, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			dir, now := setUpSystemUpgradeDir(t, time.Second)
			writeSystemUpgradeTestFile(t, dir, systemUpgradeStatusFile, SystemUpgradeStatus{
				Id: "previous", Tag: "v1.0.0-rc.44-ace.2", Phase: tt.phase,
				UpdatedAt: now.Add(-tt.age).Format(time.RFC3339),
			})

			_, err := RequestSystemUpgrade("v1.0.0-rc.44-ace.3", "v1.0.0-rc.44-ace.2", 1, now)

			if tt.blocked {
				assert.ErrorIs(t, err, ErrSystemUpgradeInProgress)
				return
			}
			require.NoError(t, err)
		})
	}
}

func TestSystemUpgradeReportsAbandonedRunAsFailed(t *testing.T) {
	dir, now := setUpSystemUpgradeDir(t, time.Second)
	writeSystemUpgradeTestFile(t, dir, systemUpgradeStatusFile, SystemUpgradeStatus{
		Id: "previous", Tag: "v1.0.0-rc.44-ace.3", Phase: SystemUpgradePhaseHealthCheck,
		UpdatedAt: now.Add(-30 * time.Minute).Format(time.RFC3339),
	})

	status := GetSystemUpgradeState(now).Status

	require.NotNil(t, status)
	assert.Equal(t, SystemUpgradePhaseFailed, status.Phase)
	assert.Equal(t, "The upgrade agent stopped responding.", status.Message)
}

func TestSystemUpgradeOutcomeIsTakenOnce(t *testing.T) {
	dir, now := setUpSystemUpgradeDir(t, time.Second)
	running := SystemUpgradeStatus{
		Id: "req-1", Tag: "v1.0.0-rc.44-ace.3", Phase: SystemUpgradePhaseRecreating,
		RequestedBy: 7, UpdatedAt: now.Format(time.RFC3339),
	}
	writeSystemUpgradeTestFile(t, dir, systemUpgradeStatusFile, running)
	assert.Nil(t, TakeFinishedSystemUpgrade(now), "a running upgrade has no outcome yet")

	finished := running
	finished.Phase = SystemUpgradePhaseSucceeded
	writeSystemUpgradeTestFile(t, dir, systemUpgradeStatusFile, finished)

	taken := TakeFinishedSystemUpgrade(now)
	require.NotNil(t, taken)
	assert.Equal(t, "req-1", taken.Id)
	assert.Equal(t, 7, taken.RequestedBy)
	assert.Nil(t, TakeFinishedSystemUpgrade(now), "the same outcome is not reported twice")

	next := finished
	next.Id, next.Phase = "req-2", SystemUpgradePhaseFailed
	writeSystemUpgradeTestFile(t, dir, systemUpgradeStatusFile, next)
	taken = TakeFinishedSystemUpgrade(now)
	require.NotNil(t, taken)
	assert.Equal(t, "req-2", taken.Id)
}
