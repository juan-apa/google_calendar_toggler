#frozen_string_literal: true

require 'bundler'
Bundler.setup

require 'dotenv/load'
require "fileutils"
require "googleauth"
require "googleauth/stores/file_token_store"
require 'google/apis/calendar_v3'
require 'json'
require 'pry'
require 'togglv8'

# Toggl Constants
TOGGL_API_KEY     = ENV['TOGGL_API_KEY']

# Google constants
OOB_URI           = "urn:ietf:wg:oauth:2.0:oob".freeze
APPLICATION_NAME  = "Google Docs API Ruby Quickstart".freeze
CREDENTIALS_PATH  = "credentials.json".freeze
TOKEN_PATH        = "token.yaml".freeze
SCOPE             = Google::Apis::CalendarV3::AUTH_CALENDAR_READONLY
GOOGLE_CAL_MAPPER = {
  "FW: Automation: Daily Scrum" => 'Automation: Daily Scrum',
  "FW: Automation: Grooming"=> 'Automation: Grooming',
  "Automation: Grooming"=> 'Automation: Grooming',
  "Automation: Retro & Planning"=> 'Automation: Retro & Planning',
  "[Internal] Q-centrix weekly Sync"=> 'Team sync',
  "Automation: Pre-Grooming"=> 'Automation: Pre-Grooming'
}

# Helper methods
def authorize
  client_id = Google::Auth::ClientId.from_file CREDENTIALS_PATH
  token_store = Google::Auth::Stores::FileTokenStore.new file: TOKEN_PATH
  authorizer = Google::Auth::UserAuthorizer.new client_id, SCOPE, token_store
  user_id = "default"
  credentials = authorizer.get_credentials user_id
  if credentials.nil?
    url = authorizer.get_authorization_url base_url: OOB_URI
    puts "Open the following URL in the browser and enter the " \
         "resulting code after authorization:\n" + url
    code = gets
    credentials = authorizer.get_and_store_credentials_from_code(
      user_id: user_id, code: code, base_url: OOB_URI
    )
  end
  credentials
end

def week_start(date, offset_from_sunday=1)
  date - (date.wday - offset_from_sunday)%7
end

def to_datetime(date)
  DateTime.parse(date.to_s+'T00:00:00-03:00')
end

def toggl_create_entry(parsed_event)
  toggl_api    = TogglV8::API.new(TOGGL_API_KEY)
  user         = toggl_api.me(all=true)
  workspaces   = toggl_api.my_workspaces(user)
  workspace_id = workspaces.first['id']
  description  = parsed_event[:summary]
  start_time   = parsed_event[:start_time]
  end_time     = parsed_event[:end_time]
  duration     = end_time.to_time.to_i - start_time.to_time.to_i
  q_centrix_project = 167143617
  param = {
    'description' => description,
    'wid' => workspace_id,
    'start' => toggl_api.iso8601(start_time),
    'duration' => duration,
    'created_with' => 'toggl_google_calendar_sync'
  }
  param.merge!('pid'=> q_centrix_project) if parsed_event[:project]
  toggl_api.create_time_entry(param)
end

def events_on_day(events, monday, day_number=0)
  events.filter do |event|
    event[:start_time].to_date.to_s == (monday + day_number).to_s
  end
end

service = Google::Apis::CalendarV3::CalendarService.new
service.client_options.application_name = APPLICATION_NAME
service.authorization = authorize

today = Date.today
monday = week_start(today)
saturday = monday + 5
events = service.list_events('primary', time_min: to_datetime(monday).to_s, time_max: to_datetime(saturday).to_s, single_events: true).items
parsed_events = events.map do |event|
  summary_present = GOOGLE_CAL_MAPPER[event.summary] ? true : false
  {
    start_time: event.start.date_time,
    end_time: event.end.date_time,
    summary: GOOGLE_CAL_MAPPER[event.summary] || event.summary,
    project: summary_present ? 'q-centrix' : nil
  }
end

# Parse into week events
week_events = {}
(0..4).each do |week_day|
  week_events[week_day] = events_on_day(parsed_events, monday, week_day)
end

# Print Summary
puts "Events count: #{parsed_events.count}"
puts "================"
week_events.keys.each do |key|
  puts "Events on day: #{key}: #{week_events[key].count}"
end

# Upload logic
puts "Do you want to upload to toggl? (0, 1, 2, 3, 4 for monday-friday | 5 everything | ctrl + c to cancell)"
upload = gets.to_i

if upload < 5
  week_events[upload].each { |parsed_event| toggl_create_entry(parsed_event) }
  puts "Uploaded day #{upload}"
elsif upload == 5
  (0..4).each do |week_day|
    week_events[week_day].each do |parsed_event|
      toggl_create_entry(parsed_event)
      puts "Uploaded day #{week_day}"
    end
  end
else
  puts "Incorrect option"
end

