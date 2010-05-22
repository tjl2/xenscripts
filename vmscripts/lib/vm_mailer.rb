require 'virtual_machine'
require 'action_mailer'

class VMMailer < ActionMailer::Base
  self.template_root = '/etc/vmscripts'
  self.delivery_method = :sendmail

  def creation_notification(recipient, rootpw, ip)
    recipients    recipient
    from          VirtualMachine::VMCREATE_EMAIL['from']
    subject       VirtualMachine::VMCREATE_EMAIL['subject']
    body          :rootpw => rootpw, :ip => ip
    content_type  "multipart/alternative"
  end
end

