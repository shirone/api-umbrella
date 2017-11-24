local common_validations = require "api-umbrella.web-app.utils.common_validations"
local json_null_default = require "api-umbrella.web-app.utils.json_null_default"
local model_ext = require "api-umbrella.web-app.utils.model_ext"
local t = require("resty.gettext").gettext
local validation_ext = require "api-umbrella.web-app.utils.validation_ext"

local validate_field = model_ext.validate_field
local validate_uniqueness = model_ext.validate_uniqueness

local ApiBackendServer
ApiBackendServer = model_ext.new_class("api_backend_servers", {
  as_json = function(self)
    return {
      id = json_null_default(self.id),
      host = json_null_default(self.host),
      port = json_null_default(self.port),
    }
  end,
}, {
  authorize = function()
    return true
  end,

  validate = function(_, data)
    local errors = {}
    validate_field(errors, data, "api_backend_id", validation_ext.string:minlen(1), t("can't be blank"))
    validate_field(errors, data, "host", validation_ext.string:minlen(1), t("can't be blank"))
    validate_field(errors, data, "host", validation_ext.db_null_optional:regex(common_validations.host_format, "jo"), t('must be in the format of "example.com"'))
    validate_field(errors, data, "port", validation_ext.number, t("can't be blank"))
    validate_field(errors, data, "port", validation_ext.number:between(0, 65535), t("is not included in the list"))
    validate_uniqueness(errors, data, "host", ApiBackendServer, {
      "api_backend_id",
      "host",
      "port",
    })
    return errors
  end,
})

return ApiBackendServer