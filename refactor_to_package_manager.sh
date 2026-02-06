#!/bin/bash
# Refactor win_vlc to generic win_package_manager role
# Run from ~/ansible directory

set -e

ANSIBLE_ROOT="$HOME/ansible"
cd "$ANSIBLE_ROOT" || exit 1

echo "=== Creating win_package_manager role structure ==="

# Create directory structure
mkdir -p roles/win_package_manager/{files,tasks,vars}

# ============================================================================
# VARS FILES
# ============================================================================

echo "Creating vars/vlc.yml..."
cat > roles/win_package_manager/vars/vlc.yml << 'EOF'
---
# VLC Media Player package configuration
package_name: "VLC"
package_version: "3.0.23"
package_zip: "vlc-3.0.23-win64.zip"
package_installer: "vlc-3.0.23-win64.exe"

# Registry detection
package_reg_key: "HKLM:\\Software\\VideoLAN\\VLC"
package_reg_value: "Version"

# Temporary paths
package_temp_dir: "C:\\Temp\\vlc"
package_log_file: "C:\\Temp\\install_vlc.log"

# Uninstall detection (display name pattern for registry search)
package_display_name_pattern: "VLC media player*"
EOF

# ============================================================================
# TASKS FILES
# ============================================================================

echo "Creating tasks/main.yml..."
cat > roles/win_package_manager/tasks/main.yml << 'EOF'
---
# Generic Windows Package Manager
# Input variables expected:
#   - mode: auto | force_install | force_uninstall
#   - reboot: yes | no
#   - Package vars loaded from vars/<package>.yml

- name: Verify mode parameter
  fail:
    msg: "Parameter 'mode' is required: auto, force_install or force_uninstall"
  when: mode is not defined

- name: Verify package configuration loaded
  fail:
    msg: "Package configuration missing. Load vars file first."
  when: package_name is not defined or package_version is not defined

- include_tasks: detect.yml
  register: detect_result

# ====================
#   MODE AUTO
# ====================
- name: "Auto-mode: upgrade if installed and outdated"
  include_tasks: upgrade.yml
  when:
    - mode == "auto"
    - detect_result.installed
    - detect_result.version != package_version

# ====================
#   MODE FORCE INSTALL
# ====================
- name: "Force install: install if absent"
  include_tasks: install.yml
  when:
    - mode == "force_install"
    - not detect_result.installed

- name: "Force install: upgrade if version mismatch"
  include_tasks: upgrade.yml
  when:
    - mode == "force_install"
    - detect_result.installed
    - detect_result.version != package_version

# ====================
#   MODE FORCE UNINSTALL
# ====================
- name: Force uninstall
  include_tasks: uninstall.yml
  when: mode == "force_uninstall"

# ====================
#   CLEANUP
# ====================
- include_tasks: cleanup.yml

# ====================
#   REBOOT HANDLING
# ====================
- name: "Reboot if requested and required"
  ansible.windows.win_reboot:
    msg: "Reboot triggered by win_package_manager ({{ package_name }})"
  when:
    - reboot | default("no") | bool
    - reboot_required | default(false) | bool

# ====================
#   OUTPUT FINAL
# ====================
- name: "Final package status"
  debug:
    msg:
      package: "{{ package_name }}"
      host: "{{ inventory_hostname }}"
      status: "{{ package_status | default('unknown') }}"
      message: "{{ package_message | default('') }}"
      reboot_required: "{{ reboot_required | default(false) }}"
EOF

echo "Creating tasks/detect.yml..."
cat > roles/win_package_manager/tasks/detect.yml << 'EOF'
---
# Detect package installation via registry

- name: "Read registry key for {{ package_name }}"
  ansible.windows.win_reg_stat:
    path: "{{ package_reg_key }}"
    name: "{{ package_reg_value }}"
  register: reg_pkg

- set_fact:
    installed: "{{ reg_pkg.exists }}"
    version: "{{ reg_pkg.value if reg_pkg.exists else 'absent' }}"

- set_fact:
    detect_result:
      installed: "{{ installed }}"
      version: "{{ version }}"

- name: "Detection result for {{ package_name }}"
  debug:
    msg: "Installed: {{ installed }}, Version: {{ version }}"
EOF

echo "Creating tasks/install.yml..."
cat > roles/win_package_manager/tasks/install.yml << 'EOF'
---
# Silent installation of package

- name: "Prepare temporary directory"
  ansible.windows.win_file:
    path: "{{ package_temp_dir }}"
    state: directory

- name: "Copy {{ package_name }} ZIP to target"
  ansible.windows.win_copy:
    src: "{{ package_zip }}"
    dest: "{{ package_temp_dir }}\\{{ package_zip }}"

- name: "Extract {{ package_name }} package"
  ansible.windows.win_shell: >
    PowerShell -NoProfile -NonInteractive -Command
    "Expand-Archive -LiteralPath '{{ package_temp_dir }}\\{{ package_zip }}' -DestinationPath '{{ package_temp_dir }}' -Force"
  args:
    creates: "{{ package_temp_dir }}\\{{ package_installer }}"

- name: "Install {{ package_name }} {{ package_version }}"
  ansible.windows.win_package:
    path: "{{ package_temp_dir }}\\{{ package_installer }}"
    arguments: "/S"
    state: present
    log_path: "{{ package_log_file }}"
  register: install_out

- set_fact:
    package_status: "installed"
    package_message: "{{ package_name }} {{ package_version }} installed"
    reboot_required: "{{ install_out.reboot_required | default(false) }}"
EOF

echo "Creating tasks/upgrade.yml..."
cat > roles/win_package_manager/tasks/upgrade.yml << 'EOF'
---
# Silent upgrade of package

- name: "Prepare temporary directory for upgrade"
  ansible.windows.win_file:
    path: "{{ package_temp_dir }}"
    state: directory

- name: "Copy {{ package_name }} ZIP to target (upgrade)"
  ansible.windows.win_copy:
    src: "{{ package_zip }}"
    dest: "{{ package_temp_dir }}\\{{ package_zip }}"

- name: "Extract {{ package_name }} package for upgrade"
  ansible.windows.win_shell: >
    PowerShell -NoProfile -NonInteractive -Command
    "Expand-Archive -LiteralPath '{{ package_temp_dir }}\\{{ package_zip }}' -DestinationPath '{{ package_temp_dir }}' -Force"
  args:
    creates: "{{ package_temp_dir }}\\{{ package_installer }}"

- name: "Upgrade {{ package_name }} to {{ package_version }}"
  ansible.windows.win_package:
    path: "{{ package_temp_dir }}\\{{ package_installer }}"
    arguments: "/S"
    state: present
    log_path: "{{ package_log_file }}"
  register: upgrade_out

- set_fact:
    package_status: "upgraded"
    package_message: "{{ package_name }} upgraded from {{ detect_result.version }} to {{ package_version }}"
    reboot_required: "{{ upgrade_out.reboot_required | default(false) }}"
EOF

echo "Creating tasks/uninstall.yml..."
cat > roles/win_package_manager/tasks/uninstall.yml << 'EOF'
---
# Clean uninstall via registry uninstall string

- name: "Search {{ package_name }} in registry (uninstall)"
  ansible.windows.win_shell: |
    $paths = @(
      'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
      'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $app = Get-ItemProperty -Path $paths -ErrorAction SilentlyContinue |
           Where-Object { $_.DisplayName -like '{{ package_display_name_pattern }}' } |
           Select-Object -First 1

    if ($app) {
      $app | Select-Object DisplayName, DisplayVersion, UninstallString, InstallLocation |
        ConvertTo-Json -Compress
    }
  register: pkg_uninstall_raw
  changed_when: false

- name: "Parse {{ package_name }} uninstall info if found"
  set_fact:
    pkg_uninstall_info: "{{ pkg_uninstall_raw.stdout | from_json }}"
  when: pkg_uninstall_raw.stdout is defined and (pkg_uninstall_raw.stdout | length > 0)

- name: "{{ package_name }} not installed: nothing to uninstall"
  set_fact:
    package_status: "unchanged"
    package_message: "{{ package_name }} not installed, no uninstall needed"
  when: pkg_uninstall_info is not defined
        or (pkg_uninstall_info.UninstallString is not defined)
        or (pkg_uninstall_info.UninstallString | string | length == 0)

- name: "Clean UninstallString (remove outer quotes)"
  set_fact:
    pkg_uninstall_path: "{{ pkg_uninstall_info.UninstallString[1:-1] }}"
  when: pkg_uninstall_info.UninstallString is defined
  
- name: "Debug cleaned uninstall path"
  debug:
    msg: "pkg_uninstall_path='{{ pkg_uninstall_path }}'"
  when: pkg_uninstall_path is defined

- name: "Uninstall {{ package_name }} via UninstallString"
  ansible.windows.win_shell: |
    Write-Output "CMD = '{{ pkg_uninstall_path }} /S'"
    Start-Process -FilePath '{{ pkg_uninstall_path }}' -ArgumentList '/S' -Wait
  args:
    executable: powershell.exe
  register: uninstall_out
  when: pkg_uninstall_path is defined

- name: "Update status after uninstall"
  set_fact:
    package_status: "{{ 'removed' if uninstall_out.rc == 0 else 'error' }}"
    package_message: >-
      {{ package_name ~ ' uninstalled'
         if uninstall_out.rc == 0
         else package_name ~ ' uninstall error (rc=' ~ uninstall_out.rc ~ ')' }}
    reboot_required: false
  when: uninstall_out is defined
EOF

echo "Creating tasks/cleanup.yml..."
cat > roles/win_package_manager/tasks/cleanup.yml << 'EOF'
---
# Cleanup temporary directory

- name: "Cleanup temporary directory for {{ package_name }}"
  ansible.windows.win_file:
    path: "{{ package_temp_dir }}"
    state: absent

- name: "Cleanup complete"
  set_fact:
    package_message: "{{ package_message }} (cleanup OK)"
EOF

# ============================================================================
# COPY VLC ZIP TO NEW LOCATION
# ============================================================================

echo "Copying VLC package to new role..."
if [ -f "roles/win_vlc/files/vlc-3.0.23-win64.zip" ]; then
    cp roles/win_vlc/files/vlc-3.0.23-win64.zip roles/win_package_manager/files/
    echo "VLC package copied successfully"
else
    echo "WARNING: VLC package not found, you'll need to copy it manually"
fi

# ============================================================================
# UPDATE PLAYBOOKS
# ============================================================================

echo "Creating updated playbooks..."

cat > playbooks/win_vlc_auto.yml << 'EOF'
---
- name: Auto-update VLC if installed
  hosts: windows
  gather_facts: false
  vars_files:
    - ../roles/win_package_manager/vars/vlc.yml
  roles:
    - role: win_package_manager
      mode: auto
      reboot: no
EOF

cat > playbooks/win_vlc_force_install.yml << 'EOF'
---
- name: Force install VLC
  hosts: windows
  gather_facts: false
  vars_files:
    - ../roles/win_package_manager/vars/vlc.yml
  roles:
    - role: win_package_manager
      mode: force_install
      reboot: no
EOF

cat > playbooks/win_vlc_force_uninstall.yml << 'EOF'
---
- name: Force uninstall VLC
  hosts: windows
  gather_facts: false
  vars_files:
    - ../roles/win_package_manager/vars/vlc.yml
  roles:
    - role: win_package_manager
      mode: force_uninstall
      reboot: no
EOF

# ============================================================================
# GIT OPERATIONS
# ============================================================================

echo ""
echo "=== Git operations ==="

# Add new role
git add roles/win_package_manager/

# Update playbooks
git add playbooks/win_vlc_auto.yml
git add playbooks/win_vlc_force_install.yml
git add playbooks/win_vlc_force_uninstall.yml

# Commit
git commit -m "Refactor: Generic win_package_manager role

- Created generic win_package_manager role
- Moved VLC config to vars/vlc.yml
- All tasks now use package_* variables
- Updated playbooks to use vars_files
- Old win_vlc role kept for reference (to be removed later)"

# Push
git push

echo ""
echo "=== Refactoring complete ==="
echo ""
echo "Next steps:"
echo "1. Test the new playbooks in AWX"
echo "2. Once validated, remove old win_vlc role:"
echo "   git rm -r roles/win_vlc"
echo "   git commit -m 'Remove old win_vlc role'"
echo "   git push"
echo ""
echo "To add a new package (e.g., tartempion):"
echo "1. Create roles/win_package_manager/vars/tartempion.yml"
echo "2. Copy tartempion ZIP to roles/win_package_manager/files/"
echo "3. Create playbooks/win_tartempion_*.yml using vars_files"
echo "4. git add, commit, push"
