module util;

import std.format,
       std.conv,
       std.array,
       std.algorithm.iteration,
       std.algorithm.searching;

import dscord.core,
       dscord.util.emitter,
       dscord.util.queue,
       dscord.util.counter;

import vibe.core.core : sleep;

// Extra struct used for storing a light amount of message data.
static private struct MessageHeapItem {
  Snowflake id;
  Snowflake authorID;

  this(Message msg) {
    this.id = msg.id;
    this.authorID = msg.author.id;
  }
}

alias MessageHeap = SizedQueue!(MessageHeapItem);

class UtilPlugin : Plugin {
  // Number of messages to keep per channel (in the heap)
  size_t messageHistoryCacheSize;

  // Event counter
  @Synced Counter!string counter;

  // Store of messages we've sent
  @Synced MessageHeap[Snowflake] msgHistory;

  // Event listener
  BaseEventListener listener;

  this() {
    super();

    this.counter = new Counter!string;
  }

  override void load(Bot bot, PluginState state = null) {
    super.load(bot, state);
    this.stateLoad!UtilPlugin(this.state);

    this.messageHistoryCacheSize = this.config.get!size_t("message_cache_size", 100);

    // Track number of times we've seen each event
    this.listener = this.bot.client.events.listenAll((name, value) {
      this.counter.tick(name);
    });
  }

  override void unload(Bot bot) {
    this.stateUnload!UtilPlugin(this.state);

    // Unbind our listener
    this.listener.unbind();

    super.unload(bot);
  }

  @Listener!MessageCreate()
  void onMessageCreate(MessageCreate event) {
    auto msg = event.message;

    // If the channel doesn't exist in our history cache, create a new heap for it
    if ((msg.channel.id in this.msgHistory) is null) {
      this.msgHistory[msg.channel.id] = new MessageHeap(this.messageHistoryCacheSize);
    // Otherwise its possible the history queue is full, so we should clear an item off
    } else if (this.msgHistory[msg.channel.id].full) {
      this.msgHistory[msg.channel.id].pop();
    }

    // Now place it on the queue
    this.msgHistory[msg.channel.id].push(MessageHeapItem(msg));
  }

  @Listener!MessageDelete()
  void onMessageDelete(MessageDelete event) {
    if ((event.channelID in this.msgHistory) is null) {
      return;
    }

    // If the queue is empty just skip this message
    if (this.msgHistory[event.channelID].empty) {
      return;
    }

    // If the message ID isn't even in the heap, skip it
    if (event.id < this.msgHistory[event.channelID].peakFront().id) {
      return;
    }

    auto msgs = this.msgHistory[event.channelID].array.filter!(msg => msg.id != event.id);
    this.msgHistory[event.channelID].clear();
    assert(this.msgHistory[event.channelID].push(msgs.array));
  }

  @Listener!MessageDeleteBulk()
  void onMessageDeleteBulk(MessageDeleteBulk event) {
    if ((event.channelID in this.msgHistory) is null) {
      return;
    }

    if (this.msgHistory[event.channelID].empty) {
      return;
    }

    auto msgs = this.msgHistory[event.channelID].array.filter!(
      msg => !event.ids.canFind(msg.id)
    );

    this.msgHistory[event.channelID].clear();
    assert(this.msgHistory[event.channelID].push(msgs.array));
  }

  @Listener!GuildDelete()
  void onGuildDelete(GuildDelete event) {
    auto guild = this.client.state.guilds.get(event.guildID, null);

    if (!guild) {
      return;
    }

    foreach (ref channel; guild.channels.keys) {
      if ((channel in this.msgHistory) !is null) {
        this.msgHistory.remove(channel);
      }
    }
  }

  @Listener!ChannelDelete()
  void onChannelDelete(ChannelDelete event) {
    if ((event.channel.id in this.msgHistory) !is null) {
      this.msgHistory.remove(event.channel.id);
    }
  }

  @Command("ping")
  void onPing(CommandEvent event) {
    event.msg.reply("pong");
  }

  @Command("jumbo")
  @CommandDescription("make an emoji jumbo sized")
  void onJumbo(CommandEvent event) {
    auto custom = event.msg.customEmojiByID();

    if (custom.length) {
      event.msg.chain.maybe.del().replyf("https://cdn.discordapp.com/emojis/%s.png", custom[0]);
    }
  }

  @Command("heapstats")
  @CommandDescription("get stats about the message heap")
  @CommandLevel(Level.ADMIN)
  void onHeapStats(CommandEvent event) {
    string msg = "";
    msg ~= format("Total Channels: %s\n", this.msgHistory.length);
    msg ~= format("Total Messages: %s", this.msgHistory.values.map!((m) => m.size).reduce!((x, y) => x + y));
    event.msg.replyf("```%s```", msg);
  }

  @Command("clean")
  @CommandDescription("clean chat by deleting previously sent messages")
  @CommandLevel(Level.MOD)
  void onClean(CommandEvent event) {
    if ((event.msg.channel.id in this.msgHistory) is null || this.msgHistory[event.msg.channel.id].empty) {
      event.msg.reply("No previously sent messages in this channel!").after(3.seconds).del();
      return;
    }

    // Grab all message ids we created from the history
    auto msgs = this.msgHistory[event.msg.channel.id].array.filter!(msg =>
      msg.authorID == this.bot.client.me.id
    ).map!(msg => msg.id).array;

    // Add the command-senders message
    msgs ~= event.msg.id;

    // Delete those messages
    this.client.deleteMessages(event.msg.channel.id, msgs);

    // Send OK message, and delete it + command msg after 3 seconds
    event.msg.reply(":recycle: :ok_hand:").after(3.seconds).del();
  }

  @Command("counts")
  @CommandGroup("event")
  @CommandDescription("view event counters")
  @CommandLevel(Level.ADMIN)
  void onEventStats(CommandEvent event) {
    ushort numEvents = 5;
    if (event.args.length >= 1) {
      numEvents = to!(ushort)(event.args[0]);
    }

    string[] parts;
    foreach (e; this.counter.mostCommon(numEvents)) {
      parts ~= format("%s: %s", e, this.counter.storage[e]);
    }

    event.msg.replyf("```%s```", parts.join("\n"));
  }

  @Command("show")
  @CommandGroup("event")
  @CommandDescription("view stats on a specific event")
  @CommandLevel(Level.ADMIN)
  void onEvent(CommandEvent event) {
    if (event.args.length < 1) {
      event.msg.reply("Please pass an event to view");
      return;
    }

    auto eventName = event.args[0];
    if (!(eventName in this.counter.storage)) {
      event.msg.reply("I don't know about that event (yet)");
      return;
    }

    event.msg.replyf("I've seen %s event a total of `%s` times!", eventName, this.counter.storage[eventName]);
  }
}

extern (C) Plugin create() {
  return new UtilPlugin;
}
