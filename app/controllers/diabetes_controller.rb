class DiabetesController < ApplicationController
  EPSILON_MINUTES = 30
  DAYS_OF_WEEK = %w[monday tuesday wednesday thursday friday
saturday sunday]

  def dashboard
  end

  def time_series
    @glucose_sensor_data_count = GlucoseSensorData.count
  end

  def day_series
    @date_extent = [
      GlucoseSensorData.minimum(:timestamp).strftime("%Y-%m-%d"),
      GlucoseSensorData.maximum(:timestamp).strftime("%Y-%m-%d")
    ]
  end

  def average_day(time, range)
    day_of_week = time.wday

    #return []

    averages = []

    (0..((60 * 24) - 1)).step(EPSILON_MINUTES) do |n|
      minutes_start = (n % 60).to_s.rjust(2, "0")
      hours_start = (n / 60).to_s.rjust(2, "0")

      # Since between operator is inclusive, we make it 1 second less than the next value
      minutes_end = ((n + EPSILON_MINUTES - 1) % 60).to_s.rjust(2, "0")
      hours_end = ((n + EPSILON_MINUTES - 1) / 60).to_s.rjust(2, "0")

      data = GlucoseSensorData.where("time between #{hours_start}#{minutes_start}00 AND #{hours_end}#{minutes_end}59").between(range[:begin], range[:end], :field => :timestamp)

      #unless range.empty?
      #  data
      #end

      timestamp = Time.utc(time.year, time.month, time.day, hours_start, minutes_start)
      datum = {
        "timestamp" => timestamp.to_s,
        "glucose" => data.average(:glucose)
      }

      averages << datum

    end

    return averages

  end

  def day_averages
    limit = (params[:limit] || 1).to_i

    year, month, day = params[:day].split("-")
    time = Date.new(year, month, day)

    max = GlucoseSensorData.maximum(:timestamp)
    range = {}
    unless range == "all"
      range = { :begin => max - limit.months, :end => max }
    end


    averages = average_day(time, range)

    render :json => averages.to_json
  end

  # Gets data for a week. Send in a day in this format: %Y-%m-%d, this function will get the nearest monday
  # through sunday. For example, hand in 12/12/12 which happens to be a wednesday. This will get days Monday,
  # 12/10/12 through Sunday 12/16/12
  def week
    stamp = params[:stamp].to_i
    interval = (params[:interval] || 10).to_i
    plus_weeks = (params[:plus_weeks] || 0).to_i
    context = (params[:context] || 0).to_i == 1 ? true : false
    time = Time.at(stamp)

    # Calculate monday from given date
    wday = time.wday
    # Adjust for sunday when we want to start on a monday
    wday = 7 if wday == 0

    date = time - (wday.days - 1.days)

    date = date + plus_weeks.weeks

    # Number of days in week range if we add context, we add the surrounding weeks as well
    days = context ? (7 * 3) - 1 : 6

    # If context we'll start at the monday before
    if context
      date -= 7.days
    end



    week_data = []
    week_dates = []

    buckets = 0.step((60 * 24) - 1, interval).to_a

    (0..days).each do |day|
      interval_data = Hash.new { |h, k| h[k] = [] }

      data = GlucoseSensorData.by_day(date.to_date, :field => :timestamp)

      data.each do |datum|
        minutes = datum.timestamp.min + (datum.timestamp.hour * 60)
        # At first seems like a no op but this actually buckets minutes into intervals
        bucket = (minutes / interval) * interval

        interval_data[bucket] << datum
      end

      week_context = nil

      if context
        week_number = day / 7
        if week_number == 0
          week_context = "before"
        elsif week_number == 1
          week_context = "current"
        else
          week_context = "after"
        end
      else
        week_context = "current"
      end

      buckets.each do |bucket|
        datum = {}

        datums = interval_data[bucket]
        # Averages glucose values if there are more than one datum for that bucket
        if datums.length > 0
          datum[:glucose] = datums.inject(0.0) { |sum, d| sum + d.glucose } / datums.size
          #datum[:timestamp] = datums[0].timestamp.to_i
        end
        datum[:timestamp] = (date + bucket.minutes).to_i
        datum[:week_context] = week_context


        datum[:time] = bucket
        datum[:day] = date.strftime("%A").downcase
        datum[:date] = date.to_i
        week_data << datum
      end

      week_dates.push({ :week_context => week_context, :day => date.strftime("%A").downcase, :date => date.to_i })
      date += 1.days
    end

    render :json => { :data => week_data, :interval => interval, :week_dates => week_dates }
  end

  # Gets data for given day format will be seconds since 1970
  def day
    stamp = params[:stamp].to_i
    time = Time.at(stamp)
    day_data = GlucoseSensorData.by_day(time.to_date, :field => :timestamp)

    #@day_data.map do |datum|
    #  datum[:glucose_scaled] = (Math.log(datum[:glucose]) - Math.log(120)) ** 2
    #end

    max = GlucoseSensorData.maximum(:timestamp)
    limit = 3
    range = {}
    unless range == "all"
      range = { :begin => max - limit.months, :end => max }
    end

    #averages = average_day(max.to_date, range)
    averages = []

    response = {
      "averages" => averages,
      "day_data" => day_data
    }

    render :json => response.to_json
  end

  def heat_map
  end

  def _get_monthly_glucose_ratios(year, global_average=0)
    monthly_ratio_list = []
    (1..12).each do |month|
      dict = {}
      if global_average != 0
        query = GlucoseSensorData.where("month = #{month}")
      else
        query = GlucoseSensorData.by_month(month, :year => year, :field => :timestamp)
      end
      total = query.count
      dict[:low] = (total != 0) ? query.where("glucose < 80").count.to_f / total : 0
      dict[:optimal] = (total != 0) ? query.where("glucose >= 80 and glucose < 180").count.to_f / total : 0
      dict[:high] = (total != 0) ? query.where("glucose >= 180").count.to_f / total : 0
      dict[:date] = Date.new(2012, month).to_s
      monthly_ratio_list << dict
    end
    return monthly_ratio_list
  end

  def get_month_glucose_ratios
    year, month, day = params[:date].split("-").map(&:to_i)
    dict = {}
    dict[:month] = {}
    dict[:week] = {}
    dict[:day] = {}

    query = GlucoseSensorData.by_month(month, :year => year, :field => :timestamp)
    total = query.count
    dict[:month][:low] = (total != 0) ? query.where("glucose < 80").count.to_f / total : 0
    dict[:month][:optimal] = (total != 0) ? query.where("glucose >= 80 and glucose < 180").count.to_f / total : 0
    dict[:month][:high] = (total != 0) ? query.where("glucose >= 180").count.to_f / total : 0

    date_obj = Date.new(year,month,day)
    query = GlucoseSensorData.by_day(date_obj, :field => :timestamp)
    total = query.count
    dict[:day][:low] = (total != 0) ? query.where("glucose < 80").count.to_f / total : 0
    dict[:day][:optimal] = (total != 0) ? query.where("glucose >= 80 and glucose < 180").count.to_f / total : 0
    dict[:day][:high] = (total != 0) ? query.where("glucose >= 180").count.to_f / total : 0

    first_day = date_obj.beginning_of_week
    query = GlucoseSensorData.between(first_day, first_day + 6.days, :field => :timestamp)
    total = query.count
    dict[:week][:low] = (total != 0) ? query.where("glucose < 80").count.to_f / total : 0
    dict[:week][:optimal] = (total != 0) ? query.where("glucose >= 80 and glucose < 180").count.to_f / total : 0
    dict[:week][:high] = (total != 0) ? query.where("glucose >= 180").count.to_f / total : 0
    render :json => dict
  end

  def get_monthly_glucose_ratios
    year, month, day = params[:date].split("-").map(&:to_i)
    global_average = params[:global_average].to_i
    data = {}
    data[:data] = _get_monthly_glucose_ratios(year)
    if global_average != 0
      data[:averages] = _get_monthly_glucose_ratios(year, global_average)
    end
    render :json => data
  end

  def get_all_daily_ratios
    data = {}
    data[:data] = _get_all_daily_ratios()
    data[:averages] = _get_all_daily_ratios(true)
    render :json => data
  end

  def _get_all_daily_ratios(compute_averages=false)
    first = GlucoseSensorData.reorder(:timestamp).first
    last = GlucoseSensorData.reorder(:timestamp).last
    boundary = last.timestamp.year + 1
    date_obj = Date.new(first.timestamp.year, 1)
    daily_ratio_list = []

    while (date_obj.next_day.year != boundary)
      dict = {}
      if compute_averages
        query = GlucoseSensorData.between(first.timestamp, last.timestamp, :field => :timestamp).where("day = #{date_obj.wday}")
      else
        query = GlucoseSensorData.by_day(date_obj, :field => :timestamp)
      end
      total = query.count
      dict[:low] = (total != 0) ? query.where("glucose < 80").count.to_f / total : 0
      dict[:optimal] = (total != 0) ? query.where("glucose >= 80 and glucose < 180").count.to_f / total : 0
      dict[:high] = (total != 0) ? query.where("glucose >= 180").count.to_f / total : 0
      dict[:date] = date_obj.to_s
      daily_ratio_list << dict
      date_obj = date_obj.next_day
    end
    return daily_ratio_list
  end

  def _get_daily_glucose_ratios(year, month, week, n_prior_weeks=0)
    date_obj = Date.new(year, month).beginning_of_week + week.weeks
    daily_ratio_list = []
    (0..6).each do |offset|
      dict = {}
      if n_prior_weeks > 0
        query = GlucoseSensorData.between(date_obj - n_prior_weeks.weeks, date_obj - 1.day, :field => :timestamp).where("day = #{date_obj.wday}")
      else
        query = GlucoseSensorData.by_day(date_obj, :field => :timestamp)
      end
      total = query.count
      dict[:low] = (total != 0) ? query.where("glucose < 80").count.to_f / total : 0
      dict[:optimal] = (total != 0) ? query.where("glucose >= 80 and glucose < 180").count.to_f / total : 0
      dict[:high] = (total != 0) ? query.where("glucose >= 180").count.to_f / total : 0
      dict[:date] = date_obj.to_s
      daily_ratio_list << dict
      date_obj += 1.day
    end
    return daily_ratio_list
  end

  def get_daily_glucose_ratios
    year, month, day = params[:date].split("-").map(&:to_i)
    #year = params[:year].to_i
    #month = params[:month].to_i + 1 # adjust for 0 index
    #week = params[:week].to_i
    week = 1
    #n_prior_weeks = params[:n_prior_weeks].to_i
    n_prior_weeks = 1
    data = {}
    data[:data] = _get_daily_glucose_ratios(year, month, week)
    if n_prior_weeks != 0
      data[:averages] = _get_daily_glucose_ratios(year, month, week, n_prior_weeks)
    end
    render :json => data
  end

  def brushing
  end

  def _get_month_data(month, year, increments)
    interval = (1.day / increments).seconds
    date_obj = Date.new(year, month)
    data = []
    while (date_obj.month == month)
      interval_start = date_obj
      cur_dict = {}
      cur_dict[:date] = date_obj
      cur_dict[:glucose] = []
      (1..increments).each do |i|
        interval_end = interval_start + interval
        cur_dict[:glucose] << GlucoseSensorData.between(interval_start, interval_end, :field => :timestamp).average(:glucose)
        interval_start = interval_end
      end
      data << cur_dict
      date_obj += 1.day
    end
    return data
  end

  def get_month_data
    year = params[:year].to_i
    month = params[:month].to_i
    increments = params[:increments].to_i
    dict = {}
    dict[:data] = _get_month_data(month, year, increments)
    render :json => dict
  end

  def get_months_data
    n_months = params[:n_months].to_i
    current = Date.strptime(params[:current], "%Y-%m-%d")
    target = Date.strptime(params[:target], "%Y-%m-%d")
    render :json => [months_between(current, target)]
  end

  def months_between(date1, date2)
      if date1 < date2
        recent_date = date1.to_date
        past_date = date2.to_date
      else
        recent_date = date2.to_date
        past_date = date1.to_date
      end
      return (past_date.month - recent_date.month) + 12 * (recent_date.year - past_date.year)
  end
end
