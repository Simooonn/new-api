package service

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"math/big"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/QuantumNous/new-api/common"
)

// System upgrades are carried out by a host agent (deploy/upgrade-agent). The
// control directory has two halves: the server writes a validated request into
// inbox/ and reads the agent's status from outbox/, which is mounted read-only.
// The server never talks to docker itself.

const (
	systemUpgradeInbox       = "inbox"
	systemUpgradeOutbox      = "outbox"
	systemUpgradeRequestFile = "request.json"
	// The server's own copy of the last request. The agent consumes
	// request.json, so this keeps the upgrade visible until the agent reports it.
	systemUpgradePendingFile = "pending.json"
	systemUpgradeStatusFile  = "status.json"
	systemUpgradeAgentFile   = "agent.json"
	// Records which finished request has already been written to the audit log.
	systemUpgradeAuditedFile = "audited"

	// The agent heartbeat timer fires every 60 seconds.
	systemUpgradeAgentTTL = 3 * time.Minute
	// A queued request the agent never picked up stops blocking new ones.
	systemUpgradeQueueTTL = 5 * time.Minute
	// A running upgrade with no status update for this long is considered dead.
	systemUpgradeRunningTTL = 20 * time.Minute
)

const (
	SystemUpgradePhaseQueued      = "queued"
	SystemUpgradePhasePulling     = "pulling"
	SystemUpgradePhaseRecreating  = "recreating"
	SystemUpgradePhaseHealthCheck = "health_check"
	SystemUpgradePhaseSucceeded   = "succeeded"
	SystemUpgradePhaseFailed      = "failed"
)

// Must stay identical to TAG_PATTERN in deploy/upgrade-agent/new-api-upgrade-agent.sh.
var systemUpgradeTagPattern = regexp.MustCompile(`^v[0-9]+(\.[0-9]+){2,}[0-9A-Za-z.-]*-ace\.[1-9][0-9]*$`)

// Mirrors parseSystemVersion in web/src/features/system-update/releases.ts so
// the server agrees with the console about which release is newer.
var systemVersionPattern = regexp.MustCompile(`^v?(\d+(?:\.\d+){2,})(?:-(alpha|beta|rc|patch)(?:\.(\d+))?(?:-i18nfix\.(\d+))?)?(?:-ace\.(\d+))?(?:\+[\da-zA-Z.-]+)?$`)

var systemVersionStages = map[string]int{"alpha": 0, "beta": 1, "rc": 2, "": 3, "patch": 4}

var (
	ErrSystemUpgradeDisabled     = common.NewMessage("Web upgrades are not enabled on this server.")
	ErrSystemUpgradeAgentOffline = common.NewMessage("The upgrade agent on the server is not running.")
	ErrSystemUpgradeInvalidTag   = common.NewMessage("This version cannot be installed from the web console.")
	ErrSystemUpgradeNotNewer     = common.NewMessage("This version is not newer than the running version.")
	ErrSystemUpgradeInProgress   = common.NewMessage("An upgrade is already in progress.")
)

var systemUpgradeMu sync.Mutex

type SystemUpgradeRequest struct {
	Id          string `json:"id"`
	Tag         string `json:"tag"`
	FromVersion string `json:"from_version"`
	RequestedBy int    `json:"requested_by"`
	RequestedAt string `json:"requested_at"`
}

type SystemUpgradeStatus struct {
	Id          string `json:"id"`
	Tag         string `json:"tag"`
	Phase       string `json:"phase"`
	Message     string `json:"message"`
	FromVersion string `json:"from_version"`
	RequestedBy int    `json:"requested_by,omitempty"`
	UpdatedAt   string `json:"updated_at"`
}

type systemUpgradeAgent struct {
	Version   string `json:"version"`
	UpdatedAt string `json:"updated_at"`
}

type SystemUpgradeState struct {
	Enabled     bool                 `json:"enabled"`
	AgentOnline bool                 `json:"agent_online"`
	Status      *SystemUpgradeStatus `json:"status"`
}

// SystemUpgradeControlDir is empty unless the deployment opted in with
// UPGRADE_CONTROL_DIR, which keeps the feature off for upstream installs.
func SystemUpgradeControlDir() string {
	return strings.TrimSpace(os.Getenv("UPGRADE_CONTROL_DIR"))
}

func GetSystemUpgradeState(now time.Time) SystemUpgradeState {
	dir := SystemUpgradeControlDir()
	if dir == "" {
		return SystemUpgradeState{}
	}
	return SystemUpgradeState{
		Enabled:     true,
		AgentOnline: systemUpgradeAgentOnline(dir, now),
		Status:      currentSystemUpgradeStatus(dir, now),
	}
}

// RequestSystemUpgrade queues an upgrade of the running server to tag.
func RequestSystemUpgrade(tag, runningVersion string, userId int, now time.Time) (*SystemUpgradeStatus, error) {
	dir := SystemUpgradeControlDir()
	if dir == "" {
		return nil, ErrSystemUpgradeDisabled
	}
	tag = strings.TrimSpace(tag)
	if !systemUpgradeTagPattern.MatchString(tag) {
		return nil, ErrSystemUpgradeInvalidTag
	}
	if _, ok := parseSystemVersion(tag); !ok {
		return nil, ErrSystemUpgradeInvalidTag
	}
	if comparison, ok := CompareSystemVersions(runningVersion, tag); ok && comparison >= 0 {
		return nil, ErrSystemUpgradeNotNewer
	}

	systemUpgradeMu.Lock()
	defer systemUpgradeMu.Unlock()

	if !systemUpgradeAgentOnline(dir, now) {
		return nil, ErrSystemUpgradeAgentOffline
	}
	if status := currentSystemUpgradeStatus(dir, now); status != nil && !systemUpgradeFinished(status.Phase) {
		return nil, ErrSystemUpgradeInProgress
	}

	id, err := newSystemUpgradeId()
	if err != nil {
		return nil, err
	}
	requestedAt := now.UTC().Format(time.RFC3339)
	request := SystemUpgradeRequest{Id: id, Tag: tag, FromVersion: runningVersion, RequestedBy: userId, RequestedAt: requestedAt}
	inbox := filepath.Join(dir, systemUpgradeInbox)
	// pending.json first, so the upgrade is never invisible once requested.
	if err := writeSystemUpgradeFile(inbox, systemUpgradePendingFile, request); err != nil {
		return nil, err
	}
	if err := writeSystemUpgradeFile(inbox, systemUpgradeRequestFile, request); err != nil {
		return nil, err
	}
	return queuedSystemUpgradeStatus(request), nil
}

func queuedSystemUpgradeStatus(request SystemUpgradeRequest) *SystemUpgradeStatus {
	return &SystemUpgradeStatus{
		Id: request.Id, Tag: request.Tag, Phase: SystemUpgradePhaseQueued,
		FromVersion: request.FromVersion, RequestedBy: request.RequestedBy, UpdatedAt: request.RequestedAt,
	}
}

// TakeFinishedSystemUpgrade returns the last finished upgrade the first time it
// is called after the upgrade ends, so its outcome is audited exactly once even
// though the process that accepted the request has been replaced.
func TakeFinishedSystemUpgrade(now time.Time) *SystemUpgradeStatus {
	dir := SystemUpgradeControlDir()
	if dir == "" {
		return nil
	}
	systemUpgradeMu.Lock()
	defer systemUpgradeMu.Unlock()
	// Only an outcome the agent reported is audited; a timed-out request may
	// still finish later and must not be recorded as failed first.
	var status SystemUpgradeStatus
	if err := readSystemUpgradeFile(filepath.Join(dir, systemUpgradeOutbox), systemUpgradeStatusFile, &status); err != nil {
		return nil
	}
	if !systemUpgradeFinished(status.Phase) || status.Id == "" {
		return nil
	}
	var audited string
	if err := readSystemUpgradeFile(filepath.Join(dir, systemUpgradeInbox), systemUpgradeAuditedFile, &audited); err == nil && audited == status.Id {
		return nil
	}
	if err := writeSystemUpgradeFile(filepath.Join(dir, systemUpgradeInbox), systemUpgradeAuditedFile, status.Id); err != nil {
		common.SysError(common.LogText("failed to record audited upgrade: %v", err))
		return nil
	}
	return &status
}

// CompareSystemVersions orders release tags the way the web console does.
// ok is false when either version cannot be parsed.
func CompareSystemVersions(left, right string) (int, bool) {
	a, okA := parseSystemVersion(left)
	b, okB := parseSystemVersion(right)
	if !okA || !okB {
		return 0, false
	}
	zero := big.NewInt(0)
	for i := range max(len(a.core), len(b.core)) {
		x, y := zero, zero
		if i < len(a.core) {
			x = a.core[i]
		}
		if i < len(b.core) {
			y = b.core[i]
		}
		if c := x.Cmp(y); c != 0 {
			return c, true
		}
	}
	for i := range a.trailer {
		if c := a.trailer[i].Cmp(b.trailer[i]); c != 0 {
			return c, true
		}
	}
	return 0, true
}

type systemVersion struct {
	core []*big.Int
	// stage, sequence, i18nfix revision, fork build number
	trailer [4]*big.Int
}

func parseSystemVersion(value string) (systemVersion, bool) {
	match := systemVersionPattern.FindStringSubmatch(strings.TrimSpace(value))
	if match == nil || (match[4] != "" && match[2] != "rc") || match[5] == "0" {
		return systemVersion{}, false
	}
	var version systemVersion
	allZero := true
	for part := range strings.SplitSeq(match[1], ".") {
		n, _ := new(big.Int).SetString(part, 10)
		allZero = allZero && n.Sign() == 0
		version.core = append(version.core, n)
	}
	if allZero {
		return systemVersion{}, false
	}
	version.trailer[0] = big.NewInt(int64(systemVersionStages[match[2]]))
	for i, group := range match[3:6] {
		n, ok := new(big.Int).SetString(group, 10)
		if !ok {
			n = big.NewInt(0)
		}
		version.trailer[i+1] = n
	}
	return version, true
}

func systemUpgradeFinished(phase string) bool {
	return phase == SystemUpgradePhaseSucceeded || phase == SystemUpgradePhaseFailed
}

func systemUpgradeAgentOnline(dir string, now time.Time) bool {
	var agent systemUpgradeAgent
	if err := readSystemUpgradeFile(filepath.Join(dir, systemUpgradeOutbox), systemUpgradeAgentFile, &agent); err != nil {
		return false
	}
	updatedAt, err := time.Parse(time.RFC3339, agent.UpdatedAt)
	return err == nil && now.Sub(updatedAt) < systemUpgradeAgentTTL
}

// currentSystemUpgradeStatus returns the latest request as queued until the
// agent reports on it, otherwise the agent's last status. One the agent
// abandoned is reported as failed so it no longer blocks new requests.
func currentSystemUpgradeStatus(dir string, now time.Time) *SystemUpgradeStatus {
	var status SystemUpgradeStatus
	reported := readSystemUpgradeFile(filepath.Join(dir, systemUpgradeOutbox), systemUpgradeStatusFile, &status) == nil && status.Phase != ""
	var pending SystemUpgradeRequest
	if err := readSystemUpgradeFile(filepath.Join(dir, systemUpgradeInbox), systemUpgradePendingFile, &pending); err == nil &&
		pending.Id != "" && (!reported || status.Id != pending.Id) {
		status = *queuedSystemUpgradeStatus(pending)
	} else if !reported {
		return nil
	}
	if systemUpgradeFinished(status.Phase) {
		return &status
	}
	updatedAt, err := time.Parse(time.RFC3339, status.UpdatedAt)
	ttl := systemUpgradeRunningTTL
	if status.Phase == SystemUpgradePhaseQueued {
		ttl = systemUpgradeQueueTTL
	}
	if err != nil || now.Sub(updatedAt) > ttl {
		status.Phase = SystemUpgradePhaseFailed
		status.Message = "The upgrade agent stopped responding."
	}
	return &status
}

func readSystemUpgradeFile(dir, name string, v any) error {
	data, err := os.ReadFile(filepath.Join(dir, name))
	if err != nil {
		return err
	}
	return common.Unmarshal(data, v)
}

// writeSystemUpgradeFile replaces the file atomically so the agent never reads
// a partial request.
func writeSystemUpgradeFile(dir, name string, v any) error {
	data, err := common.Marshal(v)
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".tmp-"+name+"-")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Chmod(tmp.Name(), 0o644); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), filepath.Join(dir, name))
}

func newSystemUpgradeId() (string, error) {
	buf := make([]byte, 8)
	if _, err := rand.Read(buf); err != nil {
		return "", errors.New("generate upgrade request id: " + err.Error())
	}
	return hex.EncodeToString(buf), nil
}
