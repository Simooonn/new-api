package controller

import (
	"errors"
	"time"

	"github.com/QuantumNous/new-api/common"
	"github.com/QuantumNous/new-api/model"
	"github.com/QuantumNous/new-api/service"

	"github.com/bytedance/gopkg/util/gopool"
	"github.com/gin-gonic/gin"
)

type systemUpgradeRequest struct {
	Tag string `json:"tag"`
}

// GetSystemUpgrade reports whether the web console can upgrade this server and
// the progress of the last upgrade.
func GetSystemUpgrade(c *gin.Context) {
	common.ApiSuccess(c, service.GetSystemUpgradeState(time.Now()))
}

// RequestSystemUpgrade hands an upgrade to the host agent and audits it.
func RequestSystemUpgrade(c *gin.Context) {
	var req systemUpgradeRequest
	if err := common.DecodeJson(c.Request.Body, &req); err != nil {
		common.ApiErrorT(c, "Invalid parameters")
		return
	}
	status, err := service.RequestSystemUpgrade(req.Tag, common.Version, c.GetInt("id"), time.Now())
	recordSystemUpgradeAudit(c, req.Tag, err)
	if err != nil {
		var message *common.Message
		if !errors.As(err, &message) {
			common.SysError(common.LogText("system upgrade request failed: %v", err))
		}
		common.ApiError(c, err)
		return
	}
	common.ApiSuccessT(c, "Upgrade started", status)
}

func recordSystemUpgradeAudit(c *gin.Context, tag string, err error) {
	action := "system.upgrade_request"
	params := map[string]any{"tag": tag, "from": common.Version}
	if err != nil {
		action = "system.upgrade_rejected"
		params["reason"] = err.Error()
	}
	auditInfo := &model.AuditRequestInfo{
		Method: c.Request.Method, Route: c.FullPath(), Path: c.FullPath(),
		Status: c.Writer.Status(), Success: err == nil,
	}
	model.RecordOperationAuditLog(c.GetInt("id"), c.GetInt("role"), auditContentEN(action, params), c.ClientIP(), action, params, auditOperatorInfo(c), auditInfo, c)
	markAuditLogged(c)
}

// StartSystemUpgradeAuditor writes the outcome of each web upgrade to the
// audit log once. It polls because the process that accepted the request is
// replaced on success, and keeps running after a failed upgrade rolls back.
// It does nothing unless UPGRADE_CONTROL_DIR is configured.
func StartSystemUpgradeAuditor() {
	if service.SystemUpgradeControlDir() == "" {
		return
	}
	gopool.Go(func() {
		ticker := time.NewTicker(30 * time.Second)
		defer ticker.Stop()
		for {
			recordFinishedSystemUpgradeAudit()
			<-ticker.C
		}
	})
}

func recordFinishedSystemUpgradeAudit() {
	status := service.TakeFinishedSystemUpgrade(time.Now())
	if status == nil {
		return
	}
	succeeded := status.Phase == service.SystemUpgradePhaseSucceeded
	action := "system.upgrade_failed"
	if succeeded {
		action = "system.upgrade_succeeded"
	}
	params := map[string]any{"tag": status.Tag, "from": status.FromVersion, "reason": status.Message}
	auditInfo := &model.AuditRequestInfo{Method: "POST", Route: "/api/system/upgrade", Path: "/api/system/upgrade", Status: 200, Success: succeeded}
	operator := &model.AuditAdminInfo{AdminID: status.RequestedBy, AdminRole: common.RoleRootUser, AuthMethod: "session"}
	model.RecordOperationAuditLog(status.RequestedBy, common.RoleRootUser, auditContentEN(action, params), "", action, params, operator, auditInfo)
}
