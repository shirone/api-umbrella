local ApiScope = require "api-umbrella.lapis.models.api_scope"
local admin_policy = require "api-umbrella.lapis.policies.admin_policy"
local api_backend_policy = require "api-umbrella.lapis.policies.api_backend_policy"
local bcrypt = require "bcrypt"
local cjson = require "cjson"
local db = require "lapis.db"
local encryptor = require "api-umbrella.utils.encryptor"
local escape_db_like = require "api-umbrella.utils.escape_db_like"
local hmac = require "api-umbrella.utils.hmac"
local is_empty = require("pl.types").is_empty
local iso8601 = require "api-umbrella.utils.iso8601"
local model_ext = require "api-umbrella.utils.model_ext"
local random_token = require "api-umbrella.utils.random_token"
local t = require("resty.gettext").gettext
local validation_ext = require "api-umbrella.utils.validation_ext"

local db_null = db.NULL
local json_null = cjson.null
local validate_field = model_ext.validate_field
local validate_uniqueness = model_ext.validate_uniqueness

local function username_field_name()
  if config["web"]["admin"]["username_is_email"] then
    return "email"
  else
    return "username"
  end
end

local function validate_email(_, data, errors)
  validate_field(errors, data, "username", validation_ext.string:minlen(1), t("can't be blank"), { error_field = username_field_name() })
  if config["web"]["admin"]["username_is_email"] then
    validate_field(errors, data, "username", validation_ext.db_null_optional:regex(config["web"]["admin"]["email_regex"], "jo"), t("is invalid"), { error_field = username_field_name() })
  else
    validate_field(errors, data, "email", validation_ext.db_null_optional:regex(config["web"]["admin"]["email_regex"], "jo"), t("is invalid"))
  end
end

local function validate_groups(_, data, errors)
  if data["superuser"] ~= true then
    validate_field(errors, data, "group_ids", validation_ext.non_null_table:minlen(1), t("must belong to at least one group or be a superuser"), { error_field = "groups" })
  end
end

local function validate_password(self, data, errors)
  local is_password_required = false
  if not is_empty(data["password"]) and data["password"] ~= db_null then
    is_password_required = true
  elseif not is_empty(data["password_confirmation"]) and data["password_confirmation"] ~= db_null then
    is_password_required = true
  end

  if is_password_required then
    validate_field(errors, data, "password", validation_ext.string:minlen(1), t("can't be blank"))
    validate_field(errors, data, "password_confirmation", validation_ext.string:minlen(1), t("can't be blank"))
    validate_field(errors, data, "password_confirmation", validation_ext.db_null_optional.string:equals(data["password"]), t("doesn't match Password"))

    local password_length_min = config["web"]["admin"]["password_length_min"]
    local password_length_max = config["web"]["admin"]["password_length_max"]
    validate_field(errors, data, "password", validation_ext.db_null_optional.string:minlen(password_length_min), string.format(t("is too short (minimum is %d characters)"), password_length_min))
    validate_field(errors, data, "password", validation_ext.db_null_optional.string:maxlen(password_length_max), string.format(t("is too long (maximum is %d characters)"), password_length_max))

    if self and self.id then
      validate_field(errors, data, "current_password", validation_ext.string:minlen(1), t("can't be blank"))
      if not is_empty(data["current_password"]) and data["current_password"] ~= db_null then
        if not self:is_valid_password(data["current_password"]) then
          model_ext.add_error(errors, "current_password", t("is invalid"))
        end
      end
    end
  end
end

local Admin
Admin = model_ext.new_class("admins", {
  relations = {
    model_ext.has_and_belongs_to_many("groups", "AdminGroup", {
      join_table = "admin_groups_admins",
      foreign_key = "admin_id",
      association_foreign_key = "admin_group_id",
      order = "name",
    }),
  },

  attributes = function(self, options)
    if not options then
      options = {
        includes = {
          groups = {},
        },
      }
    end

    return model_ext.record_attributes(self, options)
  end,

  authorize = function(self)
    admin_policy.authorize_show(ngx.ctx.current_admin, self:attributes())
  end,

  is_valid_password = function(self, password)
    if self.password_hash and password and bcrypt.verify(password, self.password_hash) then
      return true
    else
      return false
    end
  end,

  is_access_locked = function(self)
    if self.locked_at and not self:is_lock_expired() then
      return true
    else
      return false
    end
  end,

  is_lock_expired = function(self)
    if self.locked_at and self.locked_at < 0 then -- TODO
      return true
    else
      return false
    end
  end,

  authentication_token_decrypted = function(self)
    local decrypted
    if self.authentication_token_encrypted and self.authentication_token_encrypted_iv then
      decrypted = encryptor.decrypt(self.authentication_token_encrypted, self.authentication_token_encrypted_iv, self.id)
    end

    return decrypted
  end,

  group_ids = function(self)
    local group_ids = {}
    local groups = self:get_groups()
    for _, group in ipairs(groups) do
      table.insert(group_ids, group.id)
    end

    return group_ids
  end,

  group_names = function(self)
    local group_names = {}
    for _, group in ipairs(self:get_groups()) do
      table.insert(group_names, group.name)
    end
    if self.superuser then
      table.insert(group_names, t("Superuser"))
    end

    return group_names
  end,

  as_json = function(self)
    local data = {
      id = self.id or json_null,
      username = self.username or json_null,
      email = self.email or json_null,
      name = self.name or json_null,
      notes = self.notes or json_null,
      superuser = self.superuser or json_null,
      current_sign_in_provider = self.current_sign_in_provider or json_null,
      last_sign_in_provider = self.last_sign_in_provider or json_null,
      reset_password_sent_at = iso8601.format_postgres(self.reset_password_sent_at) or json_null,
      sign_in_count = self.sign_in_count or json_null,
      current_sign_in_at = iso8601.format_postgres(self.current_sign_in_at) or json_null,
      last_sign_in_at = iso8601.format_postgres(self.last_sign_in_at) or json_null,
      current_sign_in_ip = self.current_sign_in_ip or json_null,
      last_sign_in_ip = self.last_sign_in_ip or json_null,
      failed_attempts = self.failed_attempts or json_null,
      locked_at = iso8601.format_postgres(self.locked_at) or json_null,
      created_at = iso8601.format_postgres(self.created_at) or json_null,
      created_by = self.created_by_id or json_null,
      creator = {
        username = self.created_by_username or json_null,
      },
      updated_at = iso8601.format_postgres(self.updated_at) or json_null,
      updated_by = self.updated_by_id or json_null,
      updater = {
        username = self.updated_by_username or json_null,
      },
      group_ids = self:group_ids() or json_null,
      group_names = self:group_names() or json_null,
      deleted_at = json_null,
      version = 1,
    }
    setmetatable(data["group_ids"], cjson.empty_array_mt)
    setmetatable(data["group_names"], cjson.empty_array_mt)

    if ngx.ctx.current_admin and ngx.ctx.current_admin.id == self.id then
      data["authentication_token"] = self:authentication_token_decrypted()
    end

    return data
  end,

  set_reset_password_token = function(self)
    local token = random_token(24)
    local token_hash = hmac(token)
    db.update("admins", {
      reset_password_token_hash = token_hash,
      reset_password_sent_at = db.raw("now() AT TIME ZONE 'UTC'"),
    }, { id = assert(self.id) })
    self:refresh()

    return token
  end,

  api_scopes = function(self)
    return ApiScope:load_all(db.query([[
      SELECT DISTINCT api_scopes.*
      FROM api_scopes
        INNER JOIN admin_groups_api_scopes ON api_scopes.id = admin_groups_api_scopes.api_scope_id
        INNER JOIN admin_groups_admins ON admin_groups_api_scopes.admin_group_id = admin_groups_admins.admin_group_id
      WHERE admin_groups_admins.admin_id = ?]], self.id))
  end,

  -- Fetch all the API scopes this admin belongs to (through their group
  -- membership) that has a certain permission.
  api_scopes_with_permission = function(self, permission_id)
    if type(permission_id) == "string" then
      permission_id = { permission_id }
    end

    return ApiScope:load_all(db.query([[
      SELECT DISTINCT api_scopes.*
      FROM api_scopes
        INNER JOIN admin_groups_api_scopes ON api_scopes.id = admin_groups_api_scopes.api_scope_id
        INNER JOIN admin_groups_admin_permissions ON admin_groups_api_scopes.admin_group_id = admin_groups_admin_permissions.admin_group_id
        INNER JOIN admin_groups_admins ON admin_groups_api_scopes.admin_group_id = admin_groups_admins.admin_group_id
      WHERE admin_groups_admins.admin_id = ?
        AND admin_groups_admin_permissions.admin_permission_id IN ?]], self.id, db.list(permission_id)))
  end,

  -- Fetch all the API scopes this admin belongs to that has a certain
  -- permission. Differing from #api_scopes_with_permission, this also includes
  -- any nested duplicative scopes.
  --
  -- For example, if the user were explicitly granted permissions on a
  -- "api.example.com/" scope, this would also return any other sub-scopes that
  -- might exist, like "api.example.com/foo" (even if the admin account didn't
  -- have explicit permissions on that scope). This can be useful when needing
  -- a full list of scope IDs that the admin can operate on (since our prefix
  -- based approach means there might be other scopes that exist, but haven't
  -- been explicitly granted permissions to).
  nested_api_scopes_with_permission = function(self, permission_id)
    local api_scopes = self:api_scopes_with_permission(permission_id)
    if is_empty(api_scopes) then
      return api_scopes
    end

    local query = {}
    for _, api_scope in ipairs(api_scopes) do
      table.insert(query, db.interpolate_query("(host = ? AND path_prefix LIKE ? || '%')",api_scope.host, escape_db_like(api_scope.path_prefix)))
    end

    return ApiScope:select("WHERE " .. table.concat(query, " OR "))
  end,

  nested_api_scope_ids_with_permission = function(self, permission_id)
    local api_scope_ids = {}
    local api_scopes = self:nested_api_scopes_with_permission(permission_id)
    for _, api_scope in ipairs(api_scopes) do
      table.insert(api_scope_ids, api_scope.id)
    end

    return api_scope_ids
  end,

  disallowed_role_ids = function(self)
    if not self._disallowed_role_ids then
      self._disallowed_role_ids = {}
      local scope = api_backend_policy.authorized_query_scope(self, { "user_manage", "backend_manage" })
      if scope then
        local rows = db.query([[
          WITH allowed_api_backends AS (
            SELECT id FROM api_backends
            WHERE ]] .. scope .. [[
          )
          SELECT r.api_role_id
          FROM api_backend_settings_required_roles AS r
            LEFT JOIN api_backend_settings AS s ON r.api_backend_settings_id = s.id
            LEFT JOIN api_backend_sub_url_settings AS sub ON s.api_backend_sub_url_settings_id = sub.id
            LEFT JOIN allowed_api_backends AS b ON s.api_backend_id = b.id OR sub.api_backend_id = b.id
          WHERE b.id IS NULL
        ]])
        for _, row in ipairs(rows) do
          table.insert(self._disallowed_role_ids, row["api_role_id"])
        end
      end
    end

    return self._disallowed_role_ids
  end,
}, {
  authorize = function(data)
    admin_policy.authorize_modify(ngx.ctx.current_admin, data)
  end,

  before_validate_on_create = function(_, values)
    local authentication_token = random_token(40)
    values["authentication_token_hash"] = hmac(authentication_token)
    local encrypted, iv = encryptor.encrypt(authentication_token, values["id"])
    values["authentication_token_encrypted"] = encrypted
    values["authentication_token_encrypted_iv"] = iv
  end,

  before_validate = function(_, values)
    if values["superuser"] then
      -- For backwards compatibility (with how Mongoid parsed booleans), accept
      -- some alternate values for true.
      if values["superuser"] == true or values["superuser"] == 1 or values["superuser"] == "1" or values["superuser"] == "true" then
        values["superuser"] = true
      else
        values["superuser"] = false
      end
    end

    if config["web"]["admin"]["username_is_email"] and values["username"] then
      values["email"] = values["username"]
    end

    if type(values["email"]) == "string" then
      values["email"] = string.lower(values["email"])
    end

    if type(values["username"]) == "string" then
      values["username"] = string.lower(values["username"])
    end
  end,

  validate = function(self, data)
    local errors = {}
    validate_email(self, data, errors)
    validate_groups(self, data, errors)
    validate_password(self, data, errors)
    validate_field(errors, data, "superuser", validation_ext.db_null_optional.boolean, t("can't be blank"))
    validate_uniqueness(errors, data, "username", Admin, { "username" })
    return errors
  end,

  after_validate = function(_, values)
    if not is_empty(values["password"]) then
      values["password_hash"] = bcrypt.digest(values["password"], 11)
    end
  end,

  after_save = function(self, values)
    model_ext.save_has_and_belongs_to_many(self, values["group_ids"], {
      join_table = "admin_groups_admins",
      foreign_key = "admin_id",
      association_foreign_key = "admin_group_id",
    })
  end,
})

Admin.needs_first_account = function()
  local needs = false
  if config["web"]["admin"]["auth_strategies"]["_local_enabled?"] and Admin:count() == 0 then
    needs = true
  end

  return needs
end

return Admin
