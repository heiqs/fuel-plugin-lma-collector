-- Copyright 2015 Mirantis, Inc.
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

EXPORT_ASSERT_TO_GLOBALS=true
require('luaunit')
package.path = package.path .. ";files/plugins/common/?.lua;tests/lua/mocks/?.lua"

-- mock the inject_message() function from the Heka sandbox library
local last_injected_msg
function inject_message(msg)
    last_injected_msg = msg
end

local cjson = require('cjson')
local consts = require('gse_constants')

local gse = require('gse')
local gse_policy = require('gse_policy')

highest_policy = {
    gse_policy.new({
        status='down',
        trigger={
            logical_operator='or',
            rules={{
                ['function']='count',
                arguments={'down'},
                relational_operator='>',
                threshold=0
            }}
        }
    }),
    gse_policy.new({
        status='critical',
        trigger={
            logical_operator='or',
            rules={{
                ['function']='count',
                arguments={'critical'},
                relational_operator='>',
                threshold=0
            }}
        }
    }),
    gse_policy.new({
        status='warning',
        trigger={
            logical_operator='or',
            rules={{
                ['function']='count',
                arguments={'warning'},
                relational_operator='>',
                threshold=0
            }}
        }
    }),
    gse_policy.new({status='okay'})
}

-- define clusters
gse.add_cluster("heat", {'heat-api', 'controller'}, {'nova', 'glance', 'neutron', 'keystone', 'rabbitmq'}, 'member', highest_policy)
gse.add_cluster("nova", {'nova-api', 'nova-ec2-api', 'nova-scheduler'}, {'glance', 'neutron', 'keystone', 'rabbitmq'}, 'member', highest_policy)
gse.add_cluster("neutron", {'neutron-api'}, {'keystone', 'rabbitmq'}, 'member', highest_policy)
gse.add_cluster("keystone", {'keystone-admin-api', 'keystone-public-api'}, {}, 'member', highest_policy)
gse.add_cluster("glance", {'glance-api', 'glance-registry-api'}, {'keystone'}, 'member', highest_policy)
gse.add_cluster("rabbitmq", {'rabbitmq-cluster', 'controller'}, {}, 'hostname', highest_policy)

-- provision facts
gse.set_member_status("neutron", "neutron-api", consts.DOWN, {{message="All neutron endpoints are down"}}, 'node-1')
gse.set_member_status('keystone', 'keystone-admin-api', consts.OKAY, {}, 'node-1')
gse.set_member_status('glance', "glance-api", consts.WARN, {{message="glance-api endpoint is down on node-1"}}, 'node-1')
gse.set_member_status('glance', "glance-registry-api", consts.DOWN, {{message='glance-registry endpoints are down'}}, 'node-1')
gse.set_member_status("rabbitmq", 'rabbitmq-cluster', consts.WARN, {{message="1 RabbitMQ node out of 3 is down"}}, 'node-2')
gse.set_member_status("rabbitmq", 'rabbitmq-cluster', consts.OKAY, {}, 'node-1')
gse.set_member_status("rabbitmq", 'rabbitmq-cluster', consts.OKAY, {}, 'node-3')
gse.set_member_status('heat', "heat-api", consts.WARN, {{message='5xx errors detected'}}, 'node-1')
gse.set_member_status('nova', "nova-api", consts.OKAY, {}, 'node-1')
gse.set_member_status('nova', "nova-ec2_api", consts.OKAY, {}, 'node-1')
gse.set_member_status('nova', "nova-scheduler", consts.OKAY, {}, 'node-1')
gse.set_member_status('rabbitmq', "controller", consts.WARN, {{message='no space left'}}, 'node-1')
gse.set_member_status('heat', "controller", consts.WARN, {{message='no space left'}}, 'node-1')

for _, v in ipairs({'rabbitmq', 'keystone', 'glance', 'neutron', 'nova', 'heat'}) do
    gse.resolve_status(v)
end

TestGse = {}

    function TestGse:test_ordered_clusters()
        local ordered_clusters = gse.get_ordered_clusters()
        assertEquals(#ordered_clusters, 6)
        assertEquals(ordered_clusters[1], 'rabbitmq')
        assertEquals(ordered_clusters[2], 'keystone')
        assertEquals(ordered_clusters[3], 'glance')
        assertEquals(ordered_clusters[4], 'neutron')
        assertEquals(ordered_clusters[5], 'nova')
        assertEquals(ordered_clusters[6], 'heat')
    end

    function TestGse:test_01_rabbitmq_is_warning()
        local status, alarms = gse.resolve_status('rabbitmq')
        assertEquals(status, consts.WARN)
        assertEquals(#alarms, 2)
        assertEquals(alarms[1].hostname, 'node-1')
        assertEquals(alarms[1].tags.dependency_name, 'controller')
        assertEquals(alarms[1].tags.dependency_level, 'direct')
        assertEquals(alarms[2].hostname, 'node-2')
        assertEquals(alarms[2].tags.dependency_name, 'rabbitmq-cluster')
        assertEquals(alarms[2].tags.dependency_level, 'direct')
    end

    function TestGse:test_02_keystone_is_okay()
        local status, alarms = gse.resolve_status('keystone')
        assertEquals(status, consts.OKAY)
        assertEquals(#alarms, 0)
    end

    function TestGse:test_03_glance_is_down()
        local status, alarms = gse.resolve_status('glance')
        assertEquals(status, consts.DOWN)
        assertEquals(#alarms, 2)
        assert(alarms[1].hostname == nil)
        assertEquals(alarms[1].tags.dependency_name, 'glance-api')
        assertEquals(alarms[1].tags.dependency_level, 'direct')
        assert(alarms[2].hostname == nil)
        assertEquals(alarms[2].tags.dependency_name, 'glance-registry-api')
        assertEquals(alarms[2].tags.dependency_level, 'direct')
    end

    function TestGse:test_04_neutron_is_down()
        local status, alarms = gse.resolve_status('neutron')
        assertEquals(status, consts.DOWN)
        assertEquals(#alarms, 3)
        assertEquals(alarms[1].tags.dependency_name, 'neutron-api')
        assertEquals(alarms[1].tags.dependency_level, 'direct')
        assert(alarms[1].hostname == nil)
        assertEquals(alarms[2].tags.dependency_name, 'rabbitmq')
        assertEquals(alarms[2].tags.dependency_level, 'hint')
        assertEquals(alarms[2].hostname, 'node-1')
        assertEquals(alarms[3].tags.dependency_name, 'rabbitmq')
        assertEquals(alarms[3].tags.dependency_level, 'hint')
        assertEquals(alarms[3].hostname, 'node-2')
    end

    function TestGse:test_05_nova_is_okay()
        local status, alarms = gse.resolve_status('nova')
        assertEquals(status, consts.OKAY)
        assertEquals(#alarms, 0)
    end

    function TestGse:test_06_heat_is_warning_with_hints()
        local status, alarms = gse.resolve_status('heat')
        assertEquals(status, consts.WARN)
        assertEquals(#alarms, 6)
        assertEquals(alarms[1].tags.dependency_name, 'controller')
        assertEquals(alarms[1].tags.dependency_level, 'direct')
        assert(alarms[1].hostname == nil)
        assertEquals(alarms[2].tags.dependency_name, 'heat-api')
        assertEquals(alarms[2].tags.dependency_level, 'direct')
        assert(alarms[2].hostname == nil)
        assertEquals(alarms[3].tags.dependency_name, 'glance')
        assertEquals(alarms[3].tags.dependency_level, 'hint')
        assert(alarms[3].hostname == nil)
        assertEquals(alarms[4].tags.dependency_name, 'glance')
        assertEquals(alarms[4].tags.dependency_level, 'hint')
        assert(alarms[4].hostname == nil)
        assertEquals(alarms[5].tags.dependency_name, 'neutron')
        assertEquals(alarms[5].tags.dependency_level, 'hint')
        assert(alarms[5].hostname == nil)
        assertEquals(alarms[6].tags.dependency_name, 'rabbitmq')
        assertEquals(alarms[6].tags.dependency_level, 'hint')
        assertEquals(alarms[6].hostname, 'node-2')
    end

    function TestGse:test_inject_cluster_metric_for_nova()
        gse.inject_cluster_metric(
            'gse_service_cluster_metric',
            'nova',
            'service_cluster_status',
            10,
            'gse_service_cluster_plugin'
        )
        local metric = last_injected_msg
        assertEquals(metric.Type, 'gse_service_cluster_metric')
        assertEquals(metric.Fields.cluster_name, 'nova')
        assertEquals(metric.Fields.name, 'service_cluster_status')
        assertEquals(metric.Fields.value, consts.OKAY)
        assertEquals(metric.Fields.interval, 10)
        assertEquals(metric.Payload, '{"alarms":[]}')
    end

    function TestGse:test_inject_cluster_metric_for_glance()
        gse.inject_cluster_metric(
            'gse_service_cluster_metric',
            'glance',
            'service_cluster_status',
            10,
            'gse_service_cluster_plugin'
        )
        local metric = last_injected_msg
        assertEquals(metric.Type, 'gse_service_cluster_metric')
        assertEquals(metric.Fields.cluster_name, 'glance')
        assertEquals(metric.Fields.name, 'service_cluster_status')
        assertEquals(metric.Fields.value, consts.DOWN)
        assertEquals(metric.Fields.interval, 10)
        assert(metric.Payload:match("glance%-registry endpoints are down"))
        assert(metric.Payload:match("glance%-api endpoint is down on node%-1"))
    end

    function TestGse:test_inject_cluster_metric_for_heat()
        gse.inject_cluster_metric(
            'gse_service_cluster_metric',
            'heat',
            'service_cluster_status',
            10,
            'gse_service_cluster_plugin'
        )
        local metric = last_injected_msg
        assertEquals(metric.Type, 'gse_service_cluster_metric')
        assertEquals(metric.Fields.cluster_name, 'heat')
        assertEquals(metric.Fields.name, 'service_cluster_status')
        assertEquals(metric.Fields.value, consts.WARN)
        assertEquals(metric.Fields.interval, 10)
        assert(metric.Payload:match("5xx errors detected"))
        assert(metric.Payload:match("1 RabbitMQ node out of 3 is down"))
    end

    function TestGse:test_reverse_index()
        local clusters = gse.find_cluster_memberships('controller')
        assertEquals(#clusters, 2)
        assertEquals(clusters[1], 'heat')
        assertEquals(clusters[2], 'rabbitmq')
    end

lu = LuaUnit
lu:setVerbosity( 1 )
os.exit( lu:run() )
