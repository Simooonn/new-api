package controller

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/QuantumNous/new-api/common"
	"github.com/QuantumNous/new-api/middleware"
	"github.com/QuantumNous/new-api/model"
	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"
)

func TestSystemUpgradeRequestIsAuditedAndQueued(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	require.NoError(t, err)
	sqlDB, err := db.DB()
	require.NoError(t, err)
	sqlDB.SetMaxOpenConns(1)
	t.Cleanup(func() { require.NoError(t, sqlDB.Close()) })
	previousDB, previousLogDB := model.DB, model.LOG_DB
	previousMain, previousLog := common.MainDatabaseType(), common.LogDatabaseType()
	previousRedis, previousVersion := common.RedisEnabled, common.Version
	model.DB, model.LOG_DB = db, db
	common.SetDatabaseTypes(common.DatabaseTypeSQLite, common.DatabaseTypeSQLite)
	common.RedisEnabled = false
	common.Version = "v1.0.0-rc.44-ace.2"
	t.Cleanup(func() {
		model.DB, model.LOG_DB = previousDB, previousLogDB
		common.SetDatabaseTypes(previousMain, previousLog)
		common.RedisEnabled, common.Version = previousRedis, previousVersion
	})
	require.NoError(t, db.AutoMigrate(&model.User{}, &model.AuditLog{}))
	root := model.User{Username: "upgrade-root", Password: "unused", Role: common.RoleRootUser, Status: common.UserStatusEnabled, Group: "default"}
	require.NoError(t, db.Create(&root).Error)

	controlDir := t.TempDir()
	t.Setenv("UPGRADE_CONTROL_DIR", controlDir)
	agent, err := common.Marshal(map[string]string{"version": "1", "updated_at": time.Now().UTC().Format(time.RFC3339)})
	require.NoError(t, err)
	require.NoError(t, os.WriteFile(filepath.Join(controlDir, "agent.json"), agent, 0o644))

	post := func(tag string) map[string]any {
		ctx, recorder := newAuthenticatedContext(t, "POST", "/api/system/upgrade", map[string]string{"tag": tag}, root.Id)
		ctx.Set("role", common.RoleRootUser)
		ctx.Set("username", "root")
		RequestSystemUpgrade(ctx)
		var result map[string]any
		require.NoError(t, common.Unmarshal(recorder.Body.Bytes(), &result))
		return result
	}

	result := post("v1.0.0-rc.44-ace.1")
	assert.Equal(t, false, result["success"])
	assert.Equal(t, "This version is not newer than the running version.", result["message"])
	assert.NoFileExists(t, filepath.Join(controlDir, "request.json"))

	result = post("v1.0.0-rc.44-ace.3")
	require.Equal(t, true, result["success"], result)
	assert.Equal(t, "Upgrade started", result["message"])
	assert.FileExists(t, filepath.Join(controlDir, "request.json"))

	var audits []model.AuditLog
	require.NoError(t, db.Order("id").Find(&audits).Error)
	require.Len(t, audits, 2)
	assert.Equal(t, "Upgrade to v1.0.0-rc.44-ace.1 was rejected: This version is not newer than the running version.", audits[0].Content)
	assert.Equal(t, "Requested an upgrade from v1.0.0-rc.44-ace.2 to v1.0.0-rc.44-ace.3", audits[1].Content)
	assert.Equal(t, root.Id, audits[1].UserId)
}

func TestSystemUpgradeRoutesRejectAccessTokens(t *testing.T) {
	for _, key := range []string{"GET /api/system/upgrade", "POST /api/system/upgrade"} {
		rule, ok := middleware.AccessTokenRouteRule(key)
		require.True(t, ok, key)
		assert.Equal(t, "session", rule.Kind(), key)
	}
}
