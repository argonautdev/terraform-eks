data "aws_autoscaling_groups" "groups" {
  filter {
    name   = "tag-value"
    values = ["${var.cluster_name}"]
  }

  filter {
    name   = "tag-key"
    values = ["eks:cluster-name"]
  }
}

resource "null_resource" "add_tags_to_ngs" {
  for_each = local.node_groups_expanded
  triggers  =  { always_run = "${timestamp()}" }
  provisioner "local-exec" {
    command = "asg_names=`aws autoscaling describe-auto-scaling-groups --filters 'Name=tag-key,Values=eks:cluster-name' 'Name=tag-value,Values=${var.cluster_name}' --query 'AutoScalingGroups[].AutoScalingGroupName' --output text`; for eachasg in $asg_names; do if [[ $eachasg == *\"eks-${each.key}-art\"* ]];      then           aws autoscaling create-or-update-tags --tags ResourceId=$eachasg,ResourceType=auto-scaling-group,Key=ng-prefix,Value=\"eks-${each.key}-art\",PropagateAtLaunch=false;     fi; done"
  }
}

resource "null_resource" "asg-describe" {
  for_each = local.node_groups_expanded
  triggers  =  { always_run = "${timestamp()}" }
  provisioner "local-exec" {
    command = "desired_capacity=`aws autoscaling describe-auto-scaling-groups --filters 'Name=tag-key,Values=eks:cluster-name' 'Name=tag-value,Values=${var.cluster_name}' 'Name=tag-key,Values=ng-prefix' 'Name=tag-value,Values=\"eks-${each.key}-art\"' --query 'AutoScalingGroups[].DesiredCapacity' --output text`; [ ! -z \"$desired_capacity\" ] && echo $desired_capacity > \"${path.module}/${each.key}-desired.txt\" || echo ${each.value.desired_capacity} > \"${path.module}/${each.key}-desired.txt\""
  }
}

data "local_file" "desired_size" {
  depends_on = [null_resource.asg-describe]
  for_each = local.node_groups_expanded
  filename = "${path.module}/${each.key}-desired.txt"
}
  
resource "aws_eks_node_group" "workers" {
  for_each = local.node_groups_expanded

  node_group_name_prefix = lookup(each.value, "name", null) == null ? local.node_groups_names[each.key] : null
  node_group_name        = lookup(each.value, "name", null)

  cluster_name  = var.cluster_name
  node_role_arn = each.value["iam_role_arn"]
  subnet_ids    = each.value["subnets"]

  scaling_config {
    desired_size = each.value["min_capacity"] <= tonumber(trimspace(data.local_file.desired_size[each.key].content)) ? tonumber(trimspace(data.local_file.desired_size[each.key].content)) : each.value["min_capacity"]
    max_size     = each.value["max_capacity"]
    min_size     = each.value["min_capacity"]
  }

  ami_type             = lookup(each.value, "ami_type", null)
  disk_size            = each.value["launch_template_id"] != null || each.value["create_launch_template"] ? null : lookup(each.value, "disk_size", null)
  instance_types       = !each.value["set_instance_types_on_lt"] ? each.value["instance_types"] : null
  release_version      = lookup(each.value, "ami_release_version", null)
  capacity_type        = lookup(each.value, "capacity_type", null)
  force_update_version = lookup(each.value, "force_update_version", null)

  dynamic "remote_access" {
    for_each = each.value["key_name"] != "" && each.value["launch_template_id"] == null && !each.value["create_launch_template"] ? [{
      ec2_ssh_key               = each.value["key_name"]
      source_security_group_ids = lookup(each.value, "source_security_group_ids", [])
    }] : []

    content {
      ec2_ssh_key               = remote_access.value["ec2_ssh_key"]
      source_security_group_ids = remote_access.value["source_security_group_ids"]
    }
  }

  dynamic "launch_template" {
    for_each = each.value["launch_template_id"] != null ? [{
      id      = each.value["launch_template_id"]
      version = each.value["launch_template_version"]
    }] : []

    content {
      id      = launch_template.value["id"]
      version = launch_template.value["version"]
    }
  }

  dynamic "launch_template" {
    for_each = each.value["launch_template_id"] == null && each.value["create_launch_template"] ? [{
      id = aws_launch_template.workers[each.key].id
      version = each.value["launch_template_version"] == "$Latest" ? aws_launch_template.workers[each.key].latest_version : (
        each.value["launch_template_version"] == "$Default" ? aws_launch_template.workers[each.key].default_version : each.value["launch_template_version"]
      )
    }] : []

    content {
      id      = launch_template.value["id"]
      version = launch_template.value["version"]
    }
  }

  dynamic "taint" {
    for_each = each.value["taints"]

    content {
      key    = taint.value["key"]
      value  = taint.value["value"]
      effect = taint.value["effect"]
    }
  }

  version = lookup(each.value, "version", null)

  labels = merge(
    lookup(var.node_groups_defaults, "k8s_labels", {}),
    lookup(var.node_groups[each.key], "k8s_labels", {})
  )

  tags = merge(
    var.tags,
    lookup(var.node_groups_defaults, "additional_tags", {}),
    lookup(var.node_groups[each.key], "additional_tags", {}),
  )

  lifecycle {
    create_before_destroy = true
    # ignore_changes        = [scaling_config.0.desired_size]
  }

  depends_on = [var.ng_depends_on, data.local_file.desired_size]
}


###Code for adding tag prefix 
resource "aws_autoscaling_group_tag" "asg_tag" {
  for_each = local.node_groups_expanded

  autoscaling_group_name = aws_eks_node_group.workers[each.key].resources[0].autoscaling_groups[0].name

  tag {
    key   = "ng-prefix"
    value = "eks-${each.key}-art"

    propagate_at_launch = false
  }
}