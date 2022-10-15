#  var is variable. 
#  every word with var infront is a variable that will be declared later
provider "aws" {
  region = var.aws_region
}


locals {
  cluster_name = "${var.cluster_name}-${var.env_name}"
}


# we will use EKS to create and manage kubernetes installation. 
# it needs to create and manage resources to we need to setup permissions in our aws account. 
# this is a trust policy for AWS EKS to act on my behalf
# defines a new identity and access management role for our EKS service and attaches a new policy called AmazonEKSClusterPolicy to it.
# below is the rule and policies for the entire EKS cluster 
# it gives the permission to create VMs and make netowork changes as part of kubernetes management work
resource "aws_iam_role" "ms-cluster" {
  name = local.cluster_name

  assume_role_policy = <<POLICY
  {
    "Version": "2012-10-17",
    "Statement" : [
        {
            "Effect" : "Allow",
            "Principal" : {
                "Service" : "eks.amazonaws.com"
            },
            "Action" : "sts:AssumeRole"
        }
    ]
  }
  POLICY
}


resource "aws_iam_role_policy_attachment" "ms-cluster-AmazonEKSClusterPolicy" {
    policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
    role = "aws_iam_role.ms-cluster.name"
}

# Network security policy
# this will restrict the kind of traffic that can go into and out of the network

resource "aws_security_group" "ms-cluster" {
  name = local.cluster_name
  vpc_id = var.vpc_id

# the code below allow unrestricted outbound traffic but doesnt allow any inbound traffic because there is no ingress rule defined.
# we hv passed our vpc to the security group.
  egres {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    "Name" = "ms-up-running"
  }

}

# declaring the cluster itself 
# this eks is simple, it references the name, role, policy and security groups values we defined earlier. 
# also reference subnets the cluster will be managing.
# aws will create the EKS cluster and automatically setup all mangagement components we need to run our kubernetes cluster. this is called "control plane" because its the brain of our kubernetes system.

resource "aws_eks_cluster" "ms-up-running" {
  name = local.cluster_name
  role_arn = aws_iam_role.ms-cluster.arn 

  vpc_config {
    security_group_ids = [aws_security_group.ms-cluster_id]
    subnet_ids = var.cluster_subnet_ids
  }

    depends_on = [
      aws_iam_role_policy_attachment.ms-cluster-AmazonEKSClusterPolicy
    ]
                                                            
}


# we need to set up nodes. this will house our microservices. 
# nodes = physical or VMs that our containerized workloads can run on. 
# we will define a manged EKS node group and let AWS provision resources and interact with kubernetes system for us. 

# Node role 
resource "aws_iam_role" "ms-node" {
  name = "${local.cluster_name}.node"

  assume_role_policy = <<POLICY
  {
    "Version" : "2012-10-17",
    "Statement" : [
        {
            "Effect" : "Allow",
            "Principal" : {
                "Service" : "ec2.amazonaws.com"
            },
            "Action" : "sts:AssumeRole"
        }
    ]
  }
  POLICY
}

# Node policy 
# the roles and policies defined below will allow nodes to communicate with Amazon's container registries and VM services. 
resource "aws_iam_role_policy_attachment" "ms-node-AmazonEKSWorkerNodePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role = aws_iam_role.ms-node.name 
}

resource "aws_iam_policy_attachment" "ms-node-AmazonEKS_CNI_Policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role = aws_iam_role.ms-node.name
}

resource "aws_iam_role_policy_attachment" "ms-node-ContainerRegistryReadOnly" {
  policy-arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role = aws_iam_role.ms-node.name 
}

# a node group need to be configured to specify the type of compute and storage resources
# set limit on number of individual nodes or VMs that can be created automatically
# when we run this, it will instantiate a running kubernete cluster on AWS EKS service 
resource "aws_eks_node_group" "ms-node-group" {
  cluster_name = aws_eks_cluster.ms-up-running.name 
  node_group_name = "microservices"
  node_role_arn = aws_iam_role.ms-node.arn 
  subnet_ids = var.nodegroup_subnet_ids

  scaling_config {
    desired_size = var.nodegroup_desired_size
    max_size = var.nodegroup_max_size
    min_size = var.nodegroup_min_size
  }

    disk_size = var.nodegroup_disk_size
    instance_types = var.nodegroup_instance_types

    depends_on = [
      aws_iam_policy_attachment.ms-node-AmazonEKSWorkerNodePolicy,
      aws_iam_policy_attachment.ms-node-AmazonEKS_CNI_Policy,
      aws_iam_policy_attachment.ms-node-AmazonEC2ContainerRegistryReadOnly
    ]

}

# create a kubeconfig file based on the cluster that has been created
resource "local_file" "kubeconfig" {
  content  = <<KUBECONFIG
apiVersion: v1
clusters:
- cluster:
    certificate-authority-data: ${aws_eks_cluster.ms-up-running.certificate_authority.0.data}
    server: ${aws_eks_cluster.ms-up-running.endpoint}
  name: ${aws_eks_cluster.ms-up-running.arn}
contexts:
- context:
    cluster: ${aws_eks_cluster.ms-up-running.arn}
    user: ${aws_eks_cluster.ms-up-running.arn}
  name: ${aws_eks_cluster.ms-up-running.arn}
current-context: ${aws_eks_cluster.ms-up-running.arn}
kind: Config
preferences: {}
users:
- name: ${aws_eks_cluster.ms-up-running.arn}
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1alpha1
      command: aws-iam-authenticator
      args:
        - "token"
        - "-i"
        - "${aws_eks_cluster.ms-up-running.name}"
    KUBECONFIG
  filename = "kubeconfig"
}
/*
#  Use data to ensure that the cluster is up before we start using it
data "aws_eks_cluster" "msur" {
  name = aws_eks_cluster.ms-up-running.id
}
# Use kubernetes provider to work with the kubernetes cluster API
provider "kubernetes" {
  load_config_file       = false
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.msur.certificate_authority.0.data)
  host                   = data.aws_eks_cluster.msur.endpoint
  exec {
    api_version = "client.authentication.k8s.io/v1alpha1"
    command     = "aws-iam-authenticator"
    args        = ["token", "-i", "${data.aws_eks_cluster.msur.name}"]
  }
}
# Create a namespace for microservice pods 
resource "kubernetes_namespace" "ms-namespace" {
  metadata {
    name = var.ms_namespace
  }
}
*/