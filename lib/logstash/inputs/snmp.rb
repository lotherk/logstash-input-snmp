# encoding: utf-8
require 'logstash/inputs/base'
require 'logstash/namespace'
require 'thread'
require 'stud/interval'
require 'snmpjr'
require 'socket'
require 'resolv'

class LogStash::Inputs::SNMP < LogStash::Inputs::Base
  config_name 'snmp'

  default :codec, 'plain'

  config :interval, validate: :number, default: 60

  config :device, validate: :string, default: 'router'

  config :type, validate: :string, default: 'snmp'

  config :hosts, validate: :array, required: true

  config :retries, validate: :number, default: 5

  config :timeout, validate: :number, default: 5000

  config :max_oids_per_request, validate: :number, default:  20

  config :port, validate: :number, default: 161

  config :community, validate: :string, default: 'public'

  config :custom_fields, default: {}

  config :oid_table, validate: :string, default: File.join(File.dirname(__FILE__),
                                                          '../../../share/IF-MIB.yaml')

  config :iftable, validate: :array, default: ['ifIndex',
                                               'ifDescr',
                                               'ifAlias',
                                               'ifSpeed',
                                               'ifInOctets',
                                               'ifHCInOctets',
                                               'ifInUcastPkts',
                                               'ifHCInUcastPkts',
                                               'ifInNUcastPkts',
                                               'ifInDiscards',
                                               'ifInErrors',
                                               'ifInUnknownProtos',
                                               'ifInMulticastPkts',
                                               'ifHCInMulticastPkts',
                                               'ifInBroadcastPkts',
                                               'ifHCInBroadcastPkts',
                                               'ifOutOctets',
                                               'ifHCOutOctets',
                                               'ifOutUcastPkts',
                                               'ifHCOutUcastPkts',
                                               'ifOutNUcastPkts',
                                               'ifOutDiscards',
                                               'ifOutErrors',
                                               'ifOutQLen',
                                               'ifOutMulticastPkts',
                                               'ifHCOutMulticastPkts',
                                               'ifOutBroadcastPkts',
                                               'ifHCOutBroadcastPkts',
                                               'ifType']

  def register
    @self_host = Socket.gethostname
    @yaml_table = YAML.load(File.read(@oid_table))
    @snmp_hosts = {}
    @mutex = Mutex.new
    @threads = []
    @hosts.each do |h|
      snmp = Snmpjr.new(Snmpjr::Version::V2C).configure do |config|
        config.host = Resolv.getaddress(h)
        config.community = @community
        config.timeout = @timeout
        config.retries = @retries
        config.max_oids_per_request = @max_oids_per_request
      end
      @snmp_hosts[h] = snmp
    end
  end

  def run(queue)
    until stop?
      begin
        @snmp_hosts.each do |hostname, snmp|
          @threads << Thread.new do
            start = Time.now
            begin
              results = walk_host(hostname, @iftable)

              results.each do |r|
                e = LogStash::Event.new('host' => hostname)
                r.each { |k, v| e[k] = v }

                add_fields(e)

                add_custom_fields(e)

                e["poll_duration"] = Time.now - start

                decorate(e)

                @mutex.synchronize { queue << e }
              end
              runtime = Time.now - start
              if runtime > @interval
                @logger.warn "#{hostname} took #{runtime} seconds to process. " \
                "You should increase your interval for #{hostname} (current: #{@interval} seconds) " \
                "if you keep getting this warning."
              end
            rescue Exception => e
              @logger.error "Unhandled Exception in polling thread #{hostname}: #{e.message}"
              @logger.error e.backtrace.join("\n")
            end
          end
        end
        @threads.each { |t| t.join; @threads.delete(t) }
      rescue Exception => e
        @logger.error "Exception while polling SNMP: #{e.message}"
        @logger.error e.backtrace.join("\n")
      end
      Stud.stoppable_sleep(@interval) { stop? }
    end
  end

  def stop
    @logger.info "Shutting down SNMP Plugin"
    @threads.each do |t|
      t.terminate if t.alive?
    end if @threads
  end

  private

  # add custom fields
  def add_custom_fields event
    @custom_fields.each { |k, v| event[k] = v }
  end

  # add fields
  def add_fields event
    event['poll_interval'] = @interval
    event['device'] = @device
  end

  # do the snmp walk
  def walk_host host, oid_table
    snmp = @snmp_hosts[host]
    results = {}
    oid_table.each do |oid_alias|
      results[oid_alias] = snmp.walk(get_oid_by_alias(oid_alias))
    end

    results = sort_results(results)

    results
  end

  # sort results
  def sort_results results
    res = []
    results.values.first.count.times do |i|
      tmp = {}
      results.keys.each do |k|
        v = results[k][i]

        if v
          v = v.to_s
          v = v.to_i if v =~ /^\d+$/
        else
          v = 0
        end

        tmp[k] = v
      end
      res << tmp
    end
    res
  end

  # return oid by alias
  def get_oid_by_alias name
    @yaml_table[name]
  end
end
