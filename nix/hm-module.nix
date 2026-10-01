# home-manager module: installs Monitor Settings and, in place of the
# Noctalia plugin's service, reapplies the saved display configuration
# whenever the graphical session starts.
self:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.monitor-settings;
in
{
  options.programs.monitor-settings = {
    enable = lib.mkEnableOption "Monitor Settings, display arrangement and DDC/CI monitor controls";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      defaultText = lib.literalExpression "monitor-settings.packages.\${system}.default";
      description = "The Monitor Settings package to use.";
    };

    reapplyAtLogin = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Reapply the saved display configuration when the graphical session
        starts, through a oneshot systemd user service bound to
        graphical-session.target. The compositor must be started through
        systemd (UWSM, or its own systemd integration) for that target and
        WAYLAND_DISPLAY to reach user services.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.package ];

    systemd.user.services.monitor-settings-reapply = lib.mkIf cfg.reapplyAtLogin {
      Unit = {
        Description = "Reapply the saved Monitor Settings display configuration";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
      };
      Service = {
        Type = "oneshot";
        ExecStart = "${lib.getExe cfg.package} --reapply";
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };
  };
}
